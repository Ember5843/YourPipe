import { AppLog } from '../../common/AppLog';
import { TITLE_BAR_HEIGHT } from '../../common/components/MediaCardTokens';
import { VideoItem } from 'youtube_core';
import { PlaylistItem, StoredLocalQueue } from '../../common/PlaylistModel';
import { SearchPlaylistItem } from 'youtube_core';
import { VideoCard } from '../../common/components/VideoCard';
import { VideoCardGrid } from '../../common/components/VideoCardGrid';
import { PlaylistCard } from '../../features/playlist/components/PlaylistCard';
import { SearchLocaleManager } from '../../common/SearchLocaleManager';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { getFeedContentWidthVp, getVideoGridColumnCount, getWideListColumnCount } from '../../common/utils/ListLayoutUtils';
import { ActionHub } from '../../common/ActionHub';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { SubscriptionFeedItem } from '../../common/SubscriptionFeedStore';
import { FavoritesScrollCoordinator } from './FavoritesScrollCoordinator';


const logger = AppLog.getInstance('FavoritesPage');

@Component
export struct FavoritesPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('favorites') favorites: VideoItem[] = [];
  @StorageLink('playlists') playlists: PlaylistItem[] = [];
  @StorageLink('localQueues') localQueues: StoredLocalQueue[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];
  @StorageLink('subscriptionFeed') feedItems: SubscriptionFeedItem[] = [];
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;
  @State overviewMap: Record<string, SearchPlaylistItem> = {};
  @State isLoading: boolean = false;


  aboutToAppear(): void {
    this.loadOverviews();
  }

  aboutToShow(): void {
    this.loadOverviews();
  }

  private buildPlaceholder(item: PlaylistItem, index: number): SearchPlaylistItem {
    return new SearchPlaylistItem(
      index,
      item.playlistId,
      item.title || item.playlistId,
      '',
      '',
      item.coverUrl || '',
      '',
      '#CCCCCC'
    );
  }

  /** 把本地播放列表快照转成 PlaylistCard 可渲染的 SearchPlaylistItem，封面取首个视频缩略图。 */
  private buildLocalPlaylistItem(queue: StoredLocalQueue, index: number): SearchPlaylistItem {
    const cover = queue.videos.length > 0 ? (queue.videos[0].thumbnailUrl || '') : '';
    const ctx = this.getUIContext().getHostContext();
    const countText = ctx
      ? `${queue.videos.length} ${ctx.resourceManager.getStringSync($r('app.string.yt_label_favorites_videos'))}`
      : '';
    return new SearchPlaylistItem(
      index,
      queue.id,
      queue.name || '',
      '',
      countText,
      cover,
      '',
      '#CCCCCC'
    );
  }

  private async fetchOverview(item: PlaylistItem, index: number): Promise<SearchPlaylistItem> {
    const placeholder = this.buildPlaceholder(item, index);
    const playlistId = (item.playlistId || '').trim();
    if (!playlistId) {
      return placeholder;
    }
    try {
      const service = FeedServiceProvider.getInstance().getPlaylistService();
      const result = await service.fetchPlaylistOverview(playlistId);
      const countText = result && result.videoCountText && result.videoCountText.length > 0
        ? result.videoCountText
        : '';
      const coverUrl = result && result.coverUrl && result.coverUrl.length > 0
        ? result.coverUrl
        : (item.coverUrl || '');
      return new SearchPlaylistItem(
        index,
        playlistId,
        item.title || playlistId,
        '',
        countText,
        coverUrl,
        '',
        '#CCCCCC'
      );
    } catch (err) {
      logger.error('fetchOverview failed:', JSON.stringify(err));
      return placeholder;
    }
  }

  private async loadOverviews(): Promise<void> {
    if (this.playlists.length === 0) {
      return;
    }
    this.isLoading = true;
    try {
      const tasks = this.playlists.map((item, index) => this.fetchOverview(item, index));
      const results = await Promise.all(tasks);
      const next: Record<string, SearchPlaylistItem> = {};
      results.forEach((item) => {
        if (item.playlistId) {
          next[item.playlistId] = item;
        }
      });
      this.overviewMap = next;
    } catch (err) {
      logger.error('loadOverviews failed:', JSON.stringify(err));
    } finally {
      this.isLoading = false;
    }
  }

  /** 条式列表在宽屏（平板展开/2in1/电视）下的列数 */
  private getWideListColumns(): number {
    return getWideListColumnCount(getFeedContentWidthVp(this.getUIContext(), this.deviceWidth));
  }

  private getFeedCoverUrls(): string[] {
    const urls: string[] = [];
    for (const item of this.feedItems) {
      if (item.thumbnailUrl && urls.indexOf(item.thumbnailUrl) < 0) {
        urls.push(item.thumbnailUrl);
      }
      if (urls.length >= 4) {
        break;
      }
    }
    return urls;
  }

  @Builder
  private SubscriptionFeedEntry() {
    ListItem() {
      Row({ space: 12 }) {
        if (this.getFeedCoverUrls().length > 0) {
          GridRow({ columns: 2, gutter: 0 }) {
            ForEach(this.getFeedCoverUrls(), (url: string) => {
              GridCol({ span: 1 }) {
                Image(url)
                  .width(32)
                  .height(32)
                  .objectFit(ImageFit.Cover)
              }
            }, (url: string) => url)
          }
          .width(64)
          .height(64)
          .borderRadius(8)
          .clip(true)
        } else {
          Column() {
            SymbolGlyph($r('sys.symbol.person_2_fill'))
              .fontSize(28)
              .fontColor([Color.White])
          }
          .width(64)
          .height(64)
          .borderRadius(8)
          .backgroundColor(this.themePrimary)
          .justifyContent(FlexAlign.Center)
        }

        Column({ space: 4 }) {
          Text($r('app.string.yt_sub_feed_entry_title'))
            .fontSize(16)
            .fontColor($r('app.color.yourtube_text_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(getContext().resourceManager.getStringSync($r('app.string.yt_sub_feed_entry_subtitle').id, this.subscriptions.length))
            .fontSize(12)
            .fontColor($r('app.color.yourtube_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(20)
          .fontColor([$r('app.color.yourtube_text_hint')])
      }
      .width('100%')
      .padding(12)
      .backgroundColor($r('app.color.yourtube_bg_surface'))
      .borderRadius(12)
      .onClick(() => {
        this.actionHub.openSubscriptionFeed();
      })
    }
  }

  build() {
    // 顶栏避让放在外层 Column（与首页同构）：List clip(false) 让上滑内容
    // 画进避让区、透出标题栏半透明材质；scroller 绑定根标题栏滚动效果。
    Column() {
      List({ space: 4, scroller: FavoritesScrollCoordinator.scroller }) {
      this.SubscriptionFeedEntry()

      // 收藏的视频部分
      ListItem() {
        Text($r('app.string.yt_fav_videos_title'))
          .fontSize(20)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .margin({ top: 16, bottom: 12 })
          .padding({ left: 16, right: 16 })
          .width('100%')
      }

      if (!this.favorites || this.favorites.length === 0) {
        ListItem() {
          Column() {
            Text($r('app.string.yt_empty_no_fav_videos'))
              .fontSize(14)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .margin({ top: 20 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ bottom: 24 })
        }
      } else {
        if (this.uiConfig.homeLayoutMode === 'grid') {
          ListItem() {
            GridRow({
              columns: getVideoGridColumnCount(getFeedContentWidthVp(this.getUIContext(), this.deviceWidth),
                UIConfig.gridDensityOffset(this.uiConfig.homeGridDensity)),
              gutter: { x: 8, y: 8 }
            }) {
              ForEach(this.favorites, (item: VideoItem) => {
                GridCol({ span: 1 }) {
                  VideoCardGrid({
                    video: item,
                    actionLabel: $r('app.string.yt_action_unfavorite'),
                    actionType: 'remove',
                    showViewCount: false,
                    showLiveTag: false
                  })
                }
                .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
              }, (item: VideoItem) => item.videoId || item.id.toString())
            }
            .width('100%')
          }
        } else if (this.getWideListColumns() > 1) {
          ListItem() {
            GridRow({
              columns: this.getWideListColumns(),
              gutter: { x: 8, y: 4 }
            }) {
              ForEach(this.favorites, (item: VideoItem) => {
                GridCol({ span: 1 }) {
                  VideoCard({
                    video: item,
                    actionLabel: $r('app.string.yt_action_unfavorite'),
                    actionType: 'remove',
                    showViewCount: false,
                    showLiveTag: false
                  })
                }
                .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
              }, (item: VideoItem) => item.videoId || item.id.toString())
            }
            .width('100%')
          }
        } else {
          ForEach(this.favorites, (item: VideoItem) => {
            ListItem() {
              VideoCard({
                video: item,
                actionLabel: $r('app.string.yt_action_unfavorite'),
                actionType: 'remove',
                showViewCount: false,
                showLiveTag: false
              })
            }
            .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
          }, (item: VideoItem) => item.videoId || item.id.toString())
        }
      }

      // 收藏的播放列表部分
      ListItem() {
        Text($r('app.string.yt_fav_playlists_title'))
          .fontSize(20)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .margin({ top: 24, bottom: 12 })
          .padding({ left: 16, right: 16 })
          .width('100%')
      }

      if (!this.playlists || this.playlists.length === 0) {
        ListItem() {
          Column() {
            Text($r('app.string.yt_empty_no_fav_playlists'))
              .fontSize(14)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .margin({ top: 20 })
            Text($r('app.string.yt_empty_fav_playlists_hint'))
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_hint'))
              .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ bottom: 24 })
        }
      } else {
        ForEach(this.playlists, (item: PlaylistItem, index: number) => {
          ListItem() {
            PlaylistCard({
              playlist: this.overviewMap[item.playlistId]
                ? this.overviewMap[item.playlistId]
                : this.buildPlaceholder(item, index),
              typeLabel: $r('app.string.yt_filter_playlists'),
              forceActionLabel: $r('app.string.yt_action_unfavorite')
            })
          }
          .transition(customAnimationUtil.isScaleTran(item.playlistId, this.uiConfig))
        }, (item: PlaylistItem) => item.playlistId)
      }

      // 本地播放列表部分
      ListItem() {
        Text($r('app.string.yt_local_playlists_title'))
          .fontSize(20)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .margin({ top: 24, bottom: 12 })
          .padding({ left: 16, right: 16 })
          .width('100%')
      }

      if (!this.localQueues || this.localQueues.length === 0) {
        ListItem() {
          Column() {
            Text($r('app.string.yt_empty_no_local_playlists'))
              .fontSize(14)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .margin({ top: 20 })
            Text($r('app.string.yt_empty_local_playlists_hint'))
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_hint'))
              .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ bottom: 24 })
        }
      } else {
        ForEach(this.localQueues, (queue: StoredLocalQueue, index: number) => {
          ListItem() {
            PlaylistCard({
              playlist: this.buildLocalPlaylistItem(queue, index),
              typeLabel: $r('app.string.yt_local_playlists_tag')
            })
          }
          .transition(customAnimationUtil.isScaleTran(queue.id, this.uiConfig))
        }, (queue: StoredLocalQueue) => queue.id + queue.videos.length)
      }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 12, right: 12, bottom: this.safeAreaBottom + 72 })
      .clip(false)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeAreaTop + TITLE_BAR_HEIGHT })
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
