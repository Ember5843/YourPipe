import { AppLog } from '../../common/AppLog';
import inputMethod from '@ohos.inputMethod';
import { ActionHub } from '../../common/ActionHub';
import { SearchChannelItem, SearchInfoItem, SearchInfoType, SearchPlaylistItem, SearchStreamItem, SearchContentFilter } from 'youtube_core';

import { ChannelCard } from '../../features/user/components/ChannelCard';
import { VideoCard } from '../../common/components/VideoCard';
import { VideoCardGrid } from '../../common/components/VideoCardGrid';
import { ErrorPage } from '../../common/components/ErrorPage';
import { PlaylistCard } from '../../features/playlist/components/PlaylistCard';
import { LocaleBundle } from '../../common/LocaleBundle';

import { SearchLocaleManager } from '../../common/SearchLocaleManager';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { getWideListColumnCount } from '../../common/utils/ListLayoutUtils';
import { UIConfig } from '../../common/AppState';
import { SearchHistoryStore, SearchHistoryItem } from '../../common/SearchHistoryStore';
import type { BusinessError } from '@kit.BasicServicesKit';
import { HdsNavDestination } from '@kit.UIDesignKit';

const logger = AppLog.getInstance('SearchPage');

export class SearchPageLaunchParams {
  initialQuery: string;

  constructor(initialQuery: string = '') {
    this.initialQuery = initialQuery;
  }
}

@Preview
@Component
export struct SearchPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Prop initialQuery: string = '';

  @State query: string = '';
  @State results: SearchInfoItem[] = [];
  @State suggestions: string[] = [];
  @State isSearching: boolean = false;
  @State isSuggesting: boolean = false;
  @State isLoadingMore: boolean = false;
  @State hasSearched: boolean = false;
  @State nextPageToken: string | null = null;
  @State errorMessage: ResourceStr = '';
  @State isResultMode: boolean = false;
  @State activeContentFilters: string[] = [];
  @State lastOptionBeforeDialog: string = '';
  @State searchInputFocusable: boolean = this.initialQuery.trim().length === 0;
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  private isProgrammaticUpdate: boolean = false;

  private readonly SUGGESTION_DEBOUNCE_MS: number = 280;
  private readonly MAX_SUGGESTIONS: number = 12;
  private readonly GRID_GUTTER: number = 8;
  private readonly SEARCH_RESULT_SIDE_PADDING: number = 12;
  private suggestionTimer: number = -1;
  private hasAppliedInitialQuery: boolean = false;
  private isInitialSearchInFlight: boolean = false;
  @State selectedOption: string = 'yt_all';
  @State searchHistory: SearchHistoryItem[] = [];
  private dialogController: CustomDialogController | undefined = new CustomDialogController({
    builder: this.tipDialogBuilder,
    cancel: this.existApp,
    onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
      if (dismissDialogAction.reason === DismissReason.PRESS_BACK) {
        dismissDialogAction.dismiss();
      }
      if (dismissDialogAction.reason === DismissReason.TOUCH_OUTSIDE) {
        dismissDialogAction.dismiss();
      }
      if (this.selectedOption !== this.lastOptionBeforeDialog) {
        const keyword = this.query.trim();
        if (keyword.length > 0) {
          this.runSearch(true);
        }
      }
    },
    alignment: DialogAlignment.Center,
    autoCancel: true,
    cornerRadius: $r('sys.float.padding_level10')
  });


  aboutToAppear() {
    this.loadSearchHistory();
    const initialQuery = this.initialQuery.trim();
    if (!this.hasAppliedInitialQuery && initialQuery.length > 0) {
      this.hasAppliedInitialQuery = true;
      this.isProgrammaticUpdate = true;
      this.query = initialQuery;
      this.selectedOption = 'yt_all';
      this.isInitialSearchInFlight = true;
      logger.info(`auto search requested source=tag query=${initialQuery}`);
      this.runInitialSearch();
    }
  }

  aboutToDisappear() {
    this.dialogController = undefined;
  }

  private getSearchContentWidth(): number {
    const widthPx = this.deviceWidth > 0 ? this.deviceWidth : this.getUIContext().vp2px(360);
    const widthVp = this.getUIContext().px2vp(widthPx);
    return Math.max(320, widthVp - this.SEARCH_RESULT_SIDE_PADDING * 2);
  }

  private getSearchVideoColumnCount(): number {
    const width = this.getSearchContentWidth();
    if (width >= 1440) {
      return 5;
    }
    if (width >= 1080) {
      return 4;
    }
    if (width >= 760) {
      return 3;
    }
    if (width >= 520) {
      return 2;
    }
    return 1;
  }

  private getSearchVideoCardWidth(): number {
    const columns = this.getSearchVideoColumnCount();
    const contentWidth = this.getSearchContentWidth();
    return Math.floor((contentWidth - this.GRID_GUTTER * (columns - 1)) / columns);
  }

  /** 条式结果列表在宽屏（平板展开/2in1/电视）下的列数 */
  private getWideListColumns(): number {
    return getWideListColumnCount(this.getSearchContentWidth());
  }

  @Builder
  tipDialogBuilder() {
    Column() {
      Row() {
        Column() {
          Text($r('app.string.yt_search_youtube'))
            .fontSize(14)
            .fontColor($r('app.color.yourtube_text_primary'))
            .fontWeight(FontWeight.Medium)
            .margin({ bottom: 12 })

          this.OptionRow($r('app.string.yt_filter_all'), 'yt_all')
          this.OptionRow($r('app.string.yt_filter_videos'), 'yt_videos')
          this.OptionRow($r('app.string.yt_filter_channels'), 'yt_channels')
          this.OptionRow($r('app.string.yt_filter_playlists'), 'yt_playlists')
        }
        .width('50%')


        Column() {
          Text($r('app.string.yt_search_youtube_music'))
            .fontSize(14)
            .fontColor($r('app.color.yourtube_text_primary'))
            .fontWeight(FontWeight.Medium)
            .margin({ bottom: 12 })

          this.OptionRow($r('app.string.yt_filter_songs'), 'ytm_songs')
          this.OptionRow($r('app.string.yt_filter_videos'), 'ytm_videos')
          this.OptionRow($r('app.string.yt_filter_albums'), 'ytm_albums')
          this.OptionRow($r('app.string.yt_filter_playlists'), 'ytm_playlists')
        }
        .width('50%')
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)

      Divider()
        .color($r('sys.color.comp_divider'))
        .margin({ top: 12, bottom: 8 })

      Row() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(16)
          .fontColor([$r('app.color.yourtube_text_warning')])
          .margin({ right: 8 })
        Text($r('app.string.yt_action_clear_search_history'))
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_warning'))
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.dialogController?.close();
        setTimeout(() => {
          this.showClearAllConfirmDialog();
        }, 100);
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .borderRadius($r('sys.float.padding_level10'))
  }

  @Builder
  OptionRow(label: string | Resource, key: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .layoutWeight(1)
        .padding({left:8})
      Checkbox({ name: key })
        .select(this.selectedOption === key)
        .selectedColor(this.themePrimary)
        .onChange((value: boolean) => {
          if (this.selectedOption === key) {
            // 点击已选中的选项，保持弹窗打开，不做任何操作
            return;
          }
          if (!value) {
            return;
          }
          animateTo({ duration: 320, curve: Curve.EaseInOut }, () => {
            this.selectedOption = key;
          });
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6, right: 8 })
    .alignItems(VerticalAlign.Center)
    .animation({ duration: 320, curve: Curve.EaseInOut })
  }

  existApp() {
    logger.info('Click the callback in the blank area');
  }

  private getSelectedContentFilters(): string[] {
    switch (this.selectedOption) {
      case 'yt_all':
        return [SearchContentFilter.ALL];
      case 'yt_videos':
        return [SearchContentFilter.VIDEOS];
      case 'yt_channels':
        return [SearchContentFilter.CHANNELS];
      case 'yt_playlists':
        return [SearchContentFilter.PLAYLISTS];
      case 'ytm_songs':
        return [SearchContentFilter.MUSIC_SONGS];
      case 'ytm_videos':
        return [SearchContentFilter.MUSIC_VIDEOS];
      case 'ytm_albums':
        return [SearchContentFilter.MUSIC_ALBUMS];
      case 'ytm_playlists':
        return [SearchContentFilter.MUSIC_PLAYLISTS];
      default:
        return [SearchContentFilter.ALL];
    }
  }

  private async runInitialSearch(): Promise<void> {
    try {
      await this.runSearch(true);
    } finally {
      this.isInitialSearchInFlight = false;
      this.searchInputFocusable = true;
    }
  }



  private async runSearch(reset: boolean): Promise<void> {
    if (!this.query || this.query.trim().length === 0) {
      this.results = [];
      this.nextPageToken = null;
      this.suggestions = [];
      this.hasSearched = false;
      this.isResultMode = false;
      return;
    }

    if (reset) {
      SearchHistoryStore.addSearchHistory(this.query.trim());
      this.loadSearchHistory();
    }

    // Switch to Result Mode immediately
    if (reset) {
      this.isResultMode = true;
      this.isSearching = true;
      this.results = []; // Clear previous results immediately
      this.isLoadingMore = false;
      this.nextPageToken = null;
      this.activeContentFilters = this.getSelectedContentFilters();
      this.suggestions = [];
      this.hasSearched = true;
      
      // Dismiss keyboard
      try {
        inputMethod.getController().hideTextInput();
      } catch (err) {
        logger.error('Failed to hide keyboard:', JSON.stringify(err));
      }
    } else {
      if (this.isSearching || this.isLoadingMore || !this.nextPageToken) {
        return;
      }
      this.isLoadingMore = true;
    }

    const service = FeedServiceProvider.getInstance().getSearchService();
    const startId = reset ? 1 : (this.results.length + 1);
    try {
      service.setFilters(this.activeContentFilters);
      const pageResult = reset
        ? await service.searchInitial(this.query.trim(), startId)
        : await service.searchNext(this.nextPageToken ?? '', startId);
      if (reset) {
        this.results = pageResult.items;
      } else {
        this.results = [...this.results, ...pageResult.items];
      }
      this.nextPageToken = pageResult.nextPageToken;
      this.errorMessage = '';
    } catch (err) {
      logger.error('search failed:', JSON.stringify(err));
      let message = '';
      if (err && typeof err === 'object') {
        const anyErr = err as Record<string, Object>;
        message = (anyErr['message'] as string) || '';
      }
      this.errorMessage = message.length > 0 ? message : $r('app.string.yt_error_search_failed');
    } finally {
      this.isSearching = false;
      this.isLoadingMore = false;
    }
  }

  private scheduleSuggestions(): void {
    // If in Result Mode, do not schedule suggestions unless typing changes mode back (handled in onChange)
    const keyword = this.query.trim();
    if (keyword.length === 0) {
      this.suggestions = [];
      this.isSuggesting = false;
      return;
    }
    this.isSuggesting = true;
    this.suggestions = [];
    if (this.suggestionTimer >= 0) {
      clearTimeout(this.suggestionTimer);
    }
    this.suggestionTimer = setTimeout(() => {
      this.fetchSuggestions(keyword);
    }, this.SUGGESTION_DEBOUNCE_MS);
  }

  private async fetchSuggestions(keyword: string): Promise<void> {
    this.isSuggesting = true;
    try {
      const suggestionService = FeedServiceProvider.getInstance().getSearchSuggestionService();
      const suggestions = await suggestionService.fetchSuggestions(keyword);
      if (this.query.trim() !== keyword) {
        return;
      }
      this.suggestions = suggestions.slice(0, this.MAX_SUGGESTIONS);
    } catch (err) {
      logger.error('suggestions failed:', JSON.stringify(err));
      this.suggestions = [];
    } finally {
      this.isSuggesting = false;
    }
  }

  private loadSearchHistory(): void {
    this.searchHistory = SearchHistoryStore.getSearchHistory();
  }

  private showDeleteConfirmDialog(query: string): void {
    const uiContext: UIContext = this.getUIContext();
    uiContext.showAlertDialog({
      title: $r('app.string.yt_dialog_delete_search_record'),
      message: getContext().resourceManager.getStringSync($r('app.string.yt_confirm_delete_search_item').id, query),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.yt_action_cancel'),
          action: () => {}
        },
        {
          value: $r('app.string.yt_action_delete'),
          fontColor: $r('app.color.yourtube_text_warning'),
          action: () => {
            SearchHistoryStore.deleteSearchHistory(query);
            this.loadSearchHistory();
          }
        }
      ],
      cancel: () => {},
      onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
        if (dismissDialogAction.reason === DismissReason.PRESS_BACK) {
          dismissDialogAction.dismiss();
        }
        if (dismissDialogAction.reason === DismissReason.TOUCH_OUTSIDE) {
          dismissDialogAction.dismiss();
        }
      }
    });
  }

  private showClearAllConfirmDialog(): void {
    const uiContext: UIContext = this.getUIContext();
    uiContext.showAlertDialog({
      title: $r('app.string.yt_action_clear_search_history'),
      message: $r('app.string.yt_confirm_clear_search_history'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.yt_action_cancel'),
          action: () => {}
        },
        {
          value: $r('app.string.yt_action_clear'),
          fontColor: $r('app.color.yourtube_text_warning'),
          action: () => {
            SearchHistoryStore.clearSearchHistory();
            this.loadSearchHistory();
            try {
              uiContext.getPromptAction().showToast({
                message: $r('app.string.yt_toast_cleared'),
                duration: 1500
              });
            } catch (err) {
              const error: BusinessError = err as BusinessError;
              logger.error(`Show toast error: ${error.message}`);
            }
          }
        }
      ],
      cancel: () => {},
      onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
        if (dismissDialogAction.reason === DismissReason.PRESS_BACK) {
          dismissDialogAction.dismiss();
        }
        if (dismissDialogAction.reason === DismissReason.TOUCH_OUTSIDE) {
          dismissDialogAction.dismiss();
        }
      }
    });
  }

  @Builder SuggestionView() {
    Column() {
      if (this.query.trim().length === 0) {
        if (this.searchHistory.length > 0) {
          Row() {
            Text($r('app.string.yt_search_history'))
              .fontSize(14)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })

          List({ space: 4 }) {
            ForEach(this.searchHistory, (item: SearchHistoryItem) => {
              ListItem() {
                Row() {
                  SymbolGlyph($r('sys.symbol.clock'))
                    .fontSize(16)
                    .fontColor([$r('app.color.yourtube_text_quaternary')])
                    .margin({ right: 12 })
                  Text(item.query)
                    .fontSize(14)
                    .fontColor($r('app.color.yourtube_text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  SymbolGlyph($r('sys.symbol.arrow_up_left'))
                    .fontSize(16)
                    .fontColor([$r('app.color.yourtube_icon_hint')])
                    .onClick(() => {
                      this.query = item.query;
                      this.scheduleSuggestions();
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .alignItems(VerticalAlign.Center)
              }
              .onClick(() => {
                this.isProgrammaticUpdate = true;
                this.query = item.query;
                this.suggestions = [];
                this.runSearch(true);
              })
              .gesture(LongPressGesture()
                .onAction(() => {
                  this.showDeleteConfirmDialog(item.query);
                }))
            }, (item: SearchHistoryItem) => item.query + item.timestamp.toString())
          }
          .width('100%')
          .backgroundColor($r('app.color.yourtube_bg_surface'))
        } else {
          Column() {
            SymbolGlyph($r('sys.symbol.clock'))
              .fontSize(36)
              .fontColor([$r('app.color.yourtube_text_disabled')])
              .margin({ bottom: 10 })
            Text($r('app.string.yt_empty_no_search_history'))
              .fontSize(13)
              .fontColor($r('app.color.yourtube_text_quaternary'))
          }
          .width('100%')
          .padding({ top: 32 })
          .alignItems(HorizontalAlign.Center)
        }
      } else if (this.isSuggesting && this.suggestions.length === 0) {
        Row() {
          LoadingProgress()
            .color(this.themePrimary)
            .width(30)
            .height(30)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 8 })
      } else if (this.suggestions.length > 0) {
        List({ space: 4 }) {
          ForEach(this.suggestions, (item: string) => {
            ListItem() {
              Row() {
                SymbolGlyph($r('sys.symbol.magnifyingglass'))
                  .fontSize(16)
                  .fontColor([$r('app.color.yourtube_text_quaternary')])
                  .margin({ right: 12 })
                Text(item)
                  .fontSize(14)
                  .fontColor($r('app.color.yourtube_text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                SymbolGlyph($r('sys.symbol.arrow_up_left'))
                  .fontSize(16)
                  .fontColor([$r('app.color.yourtube_icon_hint')])
                  .onClick(() => {
                    this.query = item;
                    // Trigger suggestion fetch for the new term, keeping suggestion mode
                    this.scheduleSuggestions();
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .alignItems(VerticalAlign.Center)
            }
            .onClick(() => {
              this.isProgrammaticUpdate = true;
              this.query = item;
              this.suggestions = [];
              this.runSearch(true);
            })
          }, (item: string) => item)
        }
        .width('100%')
        .backgroundColor($r('app.color.yourtube_bg_surface'))
      }
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .padding({ bottom: this.safeAreaBottom + 16 })
  }

  @Builder ResultView() {
    Column() {
      if (this.isSearching && this.results.length === 0) {
        Row() {
          LoadingProgress()
            .color(this.themePrimary)
            .width(36)
            .height(36)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 20 })
      } else if (typeof this.errorMessage === 'string' && this.errorMessage.length > 0 && this.results.length === 0) {
        // 显示错误页面（有错误且无结果时）
        ErrorPage({
          errorMessage: this.errorMessage,
          onRetry: () => {
            this.runSearch(true);
          }
        })
      } else if (this.results.length > 0 || this.hasSearched) {
         if (this.results.length === 0 && this.hasSearched && !this.isSearching) {
           Column() {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(36)
              .fontColor([$r('app.color.yourtube_text_disabled')])
              .margin({ bottom: 10 })
            Text($r('app.string.yt_search_no_results'))
              .fontSize(13)
              .fontColor($r('app.color.yourtube_text_quaternary'))
          }
          .width('100%')
          .padding({ top: 32 })
          .alignItems(HorizontalAlign.Center)
         } else {
           if (this.uiConfig.homeLayoutMode === 'grid') {
             Scroll() {
               Column() {
                 Row() {
                   Text(getContext().resourceManager.getStringSync($r('app.string.yt_search_results_from').id, this.query))
                     .fontSize(12)
                     .fontColor($r('app.color.yourtube_text_secondary'))
                     .fontWeight(FontWeight.Medium)
                 }
                 .width('100%')
                 .padding({ left: 4, right: 4, top: 12, bottom: 8 })

                 Flex({
                   direction: FlexDirection.Row,
                   wrap: FlexWrap.Wrap,
                   justifyContent: FlexAlign.Start
                 }) {
                   ForEach(this.results, (item: SearchInfoItem, index: number) => {
                     if (item.type === SearchInfoType.STREAM) {
                       Column() {
                         VideoCardGrid({
                           video: (item as SearchStreamItem).video,
                           actionLabel: $r('app.string.yt_action_favorite'),
                           actionType: 'favorite',
                           typeLabel: $r('app.string.yt_filter_videos'),
                           useFavoriteToggle: true
                         })
                       }
                       .width(this.getSearchVideoCardWidth())
                       .margin({
                         right: (index + 1) % this.getSearchVideoColumnCount() === 0 ? 0 : this.GRID_GUTTER,
                         bottom: this.GRID_GUTTER
                       })
                       .transition(customAnimationUtil.isScaleTran(item.id.toString(), this.uiConfig))
                     } else if (item.type === SearchInfoType.CHANNEL) {
                       Column() {
                         ChannelCard({
                           channel: item as SearchChannelItem,
                           typeLabel: $r('app.string.yt_label_user')
                         })
                       }
                       .width('100%')
                       .margin({ bottom: this.GRID_GUTTER })
                       .transition(customAnimationUtil.isScaleTran(item.id.toString(), this.uiConfig))
                     } else if (item.type === SearchInfoType.PLAYLIST) {
                       Column() {
                         PlaylistCard({
                           playlist: item as SearchPlaylistItem,
                           typeLabel: $r('app.string.yt_filter_playlists')
                         })
                       }
                       .width('100%')
                       .margin({ bottom: this.GRID_GUTTER })
                       .transition(customAnimationUtil.isScaleTran(item.id.toString(), this.uiConfig))
                     }
                   }, (item: SearchInfoItem) => item.id.toString())
                 }
                 .width('100%')

                 if (this.isLoadingMore) {
                   Row() {
                     LoadingProgress()
                       .color(this.themePrimary)
                       .width(30)
                       .height(30)
                   }
                   .width('100%')
                   .justifyContent(FlexAlign.Center)
                   .padding({ top: 12, bottom: 12 })
                 }
               }
               .width('100%')
             }
              .width('100%')
              .layoutWeight(1)
              .backgroundColor($r('app.color.yourtube_bg_page'))
              .padding({ left: 12, right: 12, top: 4, bottom: this.safeAreaBottom + 16 })
              .edgeEffect(EdgeEffect.Spring)
              .onReachEnd(() => {
                this.runSearch(false);
              })
            } else if (this.getWideListColumns() > 1) {
              Scroll() {
                Column() {
                  Row() {
                    Text(getContext().resourceManager.getStringSync($r('app.string.yt_search_results_from').id, this.query))
                      .fontSize(12)
                      .fontColor($r('app.color.yourtube_text_secondary'))
                      .fontWeight(FontWeight.Medium)
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 12, bottom: 4 })

                  GridRow({
                    columns: this.getWideListColumns(),
                    gutter: { x: this.GRID_GUTTER, y: 4 }
                  }) {
                    ForEach(this.results, (item: SearchInfoItem) => {
                      if (item.type === SearchInfoType.STREAM) {
                        GridCol({ span: 1 }) {
                          VideoCard({
                            video: (item as SearchStreamItem).video,
                            actionLabel: $r('app.string.yt_action_favorite'),
                            actionType: 'favorite',
                            typeLabel: $r('app.string.yt_filter_videos'),
                            useFavoriteToggle: true
                          })
                        }
                        .transition(customAnimationUtil.isScaleTran(item.id.toString(), this.uiConfig))
                      } else if (item.type === SearchInfoType.CHANNEL) {
                        GridCol({ span: this.getWideListColumns() }) {
                          ChannelCard({
                            channel: item as SearchChannelItem,
                            typeLabel: $r('app.string.yt_label_user')
                          })
                        }
                        .transition(customAnimationUtil.isScaleTran(item.id.toString(), this.uiConfig))
                      } else if (item.type === SearchInfoType.PLAYLIST) {
                        GridCol({ span: this.getWideListColumns() }) {
                          PlaylistCard({
                            playlist: item as SearchPlaylistItem,
                            typeLabel: $r('app.string.yt_filter_playlists')
                          })
                        }
                        .transition(customAnimationUtil.isScaleTran(item.id.toString(), this.uiConfig))
                      }
                    }, (item: SearchInfoItem) => item.id.toString())
                  }
                  .width('100%')

                  if (this.isLoadingMore) {
                    Row() {
                      LoadingProgress()
                        .color(this.themePrimary)
                        .width(30)
                        .height(30)
                    }
                    .width('100%')
                    .justifyContent(FlexAlign.Center)
                    .padding({ top: 12, bottom: 12 })
                  }
                }
                .width('100%')
              }
              .width('100%')
              .layoutWeight(1)
              .backgroundColor($r('app.color.yourtube_bg_page'))
              .padding({ left: 12, right: 12, top: 4, bottom: this.safeAreaBottom + 16 })
              .edgeEffect(EdgeEffect.Spring)
              .onReachEnd(() => {
                this.runSearch(false);
              })
            } else {
              List({ space: 4 }) {
                ListItem() {
                  Row() {
                    Text(getContext().resourceManager.getStringSync($r('app.string.yt_search_results_from').id, this.query))
                     .fontSize(12)
                     .fontColor($r('app.color.yourtube_text_secondary'))
                     .fontWeight(FontWeight.Medium)
                 }
                 .width('100%')
                 .padding({ left: 16, right: 16, top: 12, bottom: 4 })
               }

              ForEach(this.results, (item: SearchInfoItem, index: number) => {
                 ListItem() {
                  if (item.type === SearchInfoType.STREAM) {
                    VideoCard({
                      video: (item as SearchStreamItem).video,
                      actionLabel: $r('app.string.yt_action_favorite'),
                      actionType: 'favorite',
                      typeLabel: $r('app.string.yt_filter_videos'),
                      useFavoriteToggle: true
                    })
                  } else if (item.type === SearchInfoType.CHANNEL) {
                    ChannelCard({
                      channel: item as SearchChannelItem,
                      typeLabel: $r('app.string.yt_label_user')
                    })
                  } else if (item.type === SearchInfoType.PLAYLIST) {
                    PlaylistCard({
                      playlist: item as SearchPlaylistItem,
                      typeLabel: $r('app.string.yt_filter_playlists')
                    })
                  }
                 }
                 .transition(customAnimationUtil.isScaleTran(index, this.uiConfig))
              }, (item: SearchInfoItem) => item.id.toString())

               if (this.isLoadingMore) {
                 ListItem() {
                   Row() {
                     LoadingProgress()
                       .color(this.themePrimary)
                       .width(30)
                       .height(30)
                   }
                   .width('100%')
                   .justifyContent(FlexAlign.Center)
                 }
               }
             }
              .width('100%')
              .layoutWeight(1)
              .backgroundColor($r('app.color.yourtube_bg_page'))
              .padding({ left: 12, right: 12, top: 4, bottom: this.safeAreaBottom + 16 })
              .edgeEffect(EdgeEffect.Spring)
              .onReachEnd(() => {
                this.runSearch(false);
              })
            }
          }
       }
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }

  @Builder
  SearchInputBar() {
    Search({ value: this.query, placeholder: $r('app.string.yt_placeholder_search_content') })
      .textFont({ size: 14 })
      .placeholderFont({ size: 14 })
      .fontColor($r('app.color.yourtube_text_primary'))
      .placeholderColor($r('app.color.yourtube_text_hint'))
      .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
      .height(40)
      .layoutWeight(1)
      .defaultFocus(this.initialQuery.trim().length === 0)
      .focusable(this.searchInputFocusable)
      .borderRadius(20)
      .shadow({ radius: 4, color: $r('app.color.yourtube_shadow'), offsetX: 0, offsetY: 2 })
      .searchIcon({
        size: 20,
        color: $r('app.color.yourtube_text_hint')
      })
      .cancelButton({
        style: CancelButtonStyle.INVISIBLE
      })
      .searchButton($r('app.string.yt_placeholder_search'), {
        fontSize: 16,
        fontColor: this.themePrimary,
        autoDisable: false
      })
      .onFocus(() => {
        if (this.isInitialSearchInFlight) {
          logger.debug('initial tag search ignored automatic focus');
          return;
        }
        this.isResultMode = false;
        if (this.query.trim().length > 0) {
          this.scheduleSuggestions();
        }
      })
      .onChange((value: string) => {
        this.query = value;
        if (this.isProgrammaticUpdate) {
          this.isProgrammaticUpdate = false;
          return;
        }
        this.isResultMode = false;
        this.scheduleSuggestions();
      })
      .onSubmit(() => {
        this.runSearch(true);
      })
  }

  @Builder
  SearchTitleBar() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.arrow_left'))
          .fontSize(22)
          .fontColor([$r('app.color.yourtube_text_primary')])
      }
      .width(40)
      .height(40)
      .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
      .shadow({ radius: 4, color: $r('app.color.yourtube_shadow'), offsetX: 0, offsetY: 2 })
      .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
      .onClick(() => {
        this.actionHub.closePage();
      })

      this.SearchInputBar()

      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.line_3_horizontal'))
          .fontSize(22)
          .fontColor([$r('app.color.yourtube_text_primary')])
      }
      .width(40)
      .height(40)
      .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
      .shadow({ radius: 4, color: $r('app.color.yourtube_shadow'), offsetX: 0, offsetY: 2 })
      .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
      .onClick(() => {
        this.lastOptionBeforeDialog = this.selectedOption;
        this.dialogController?.open();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: this.safeAreaTop + 56 })
    .padding({ left: 12, right: 12, top: this.safeAreaTop + 8, bottom: 8 })
    .backgroundColor($r('app.color.yourtube_bg_page'))
    .shadow({ radius: 8, color: $r('app.color.yourtube_shadow'), offsetX: 0, offsetY: 2 })
  }

  build() {
    HdsNavDestination() {
      Column() {
        this.SearchTitleBar()

        if (this.isResultMode) {
          this.ResultView()
        } else {
          this.SuggestionView()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.yourtube_bg_page'))
    }
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.actionHub.closePage();
      return true;
    })
  }
}
