import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { OptionItem } from '../../common/components/OptionItem';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import {
  ExperimentalConfig,
  EXP_AILIST_MODE_HIDE,
  EXP_AILIST_MODE_MARK,
  EXP_AILIST_SYNC_DAYS_VALUES
} from '../../common/experimental/ExperimentalConfig';
import { AiListStatus, AiListStore } from '../../common/experimental/AiListStore';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('OptionsAiListPage');

interface AiListPageParams {
  updateConfig: (mutator: (cfg: ExperimentalConfig) => void) => void;
}

@Component
export struct OptionsAiListPage {
  @StorageLink('experimentalConfig') cfg: ExperimentalConfig = new ExperimentalConfig();
  @StorageLink('aiListStatus') status: AiListStatus = new AiListStatus();
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop params: AiListPageParams = {
    updateConfig: () => {}
  };

  private modeOptions(): SelectOption[] {
    return [
      { value: $r('app.string.yt_exp_ai_mode_mark') } as SelectOption,
      { value: $r('app.string.yt_exp_ai_mode_hide') } as SelectOption
    ];
  }

  private modeIndex(): number {
    return this.cfg.aiListMode === EXP_AILIST_MODE_HIDE ? 1 : 0;
  }

  private syncOptions(): SelectOption[] {
    return [
      { value: $r('app.string.yt_exp_ai_sync_daily') } as SelectOption,
      { value: $r('app.string.yt_exp_ai_sync_weekly') } as SelectOption,
      { value: $r('app.string.yt_exp_ai_sync_manual') } as SelectOption
    ];
  }

  private syncIndex(): number {
    const index = EXP_AILIST_SYNC_DAYS_VALUES.indexOf(this.cfg.aiListSyncDays);
    return index >= 0 ? index : 0;
  }

  private statusText(): string {
    if (this.status.syncing) {
      return getContext().resourceManager.getStringSync($r('app.string.yt_exp_ai_syncing').id);
    }
    if (this.status.error.length > 0) {
      return getContext().resourceManager.getStringSync($r('app.string.yt_exp_ai_sync_failed').id);
    }
    if (this.status.lastSyncMs <= 0) {
      return getContext().resourceManager.getStringSync($r('app.string.yt_exp_ai_never').id);
    }
    const date = new Date(this.status.lastSyncMs).toLocaleString();
    return getContext().resourceManager.getStringSync(
      $r('app.string.yt_exp_ai_status').id, date, this.status.blockCount + this.status.warnCount);
  }

  private syncNow(): void {
    if (this.status.syncing) {
      return;
    }
    logger.info('manual sync requested');
    AiListStore.getInstance().syncNow().catch((_e: Error) => {});
  }

  private clearCache(): void {
    AiListStore.getInstance().clear();
    this.params.updateConfig((cfg: ExperimentalConfig) => {
      cfg.aiListLastSyncMs = 0;
    });
    this.getUIContext().getPromptAction().showToast({
      message: $r('app.string.yt_exp_cache_cleared'),
      duration: 2000
    });
  }

  build() {
    List({ space: 6 }) {
      ListItem() {
        Text($r('app.string.yt_exp_ai_desc'))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_hint'))
          .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      }

      ListItem() {
        Column() {
          PlaybackToggleRow({
            title: $r('app.string.yt_exp_ai_title'),
            isOn: this.cfg.aiListEnabled,
            themeColor: this.themePrimary,
            transparentBackground: true,
            onChange: (value: boolean) => {
              logger.info(`ailist master=${value}`);
              this.params.updateConfig((cfg: ExperimentalConfig) => {
                cfg.aiListEnabled = value;
              });
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
      }
      .padding({ left: 16, right: 16 })

      if (this.cfg.aiListEnabled) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_exp_ai_title') })
        }
        .padding({ left: 16, right: 16, top: 8 })

        ListItem() {
          Column() {
            PlaybackSelectRow({
              title: $r('app.string.yt_exp_ai_mode'),
              options: this.modeOptions(),
              selectedIndex: this.modeIndex(),
              fontColor: this.themePrimary,
              transparentBackground: true,
              onChange: (index: number) => {
                const mode = index === 1 ? EXP_AILIST_MODE_HIDE : EXP_AILIST_MODE_MARK;
                this.params.updateConfig((cfg: ExperimentalConfig) => {
                  cfg.aiListMode = mode;
                });
                logger.info(`mode=${mode}`);
              }
            })
            Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
            PlaybackToggleRow({
              title: $r('app.string.yt_exp_ai_warnlist'),
              isOn: this.cfg.aiListWarnList,
              themeColor: this.themePrimary,
              transparentBackground: true,
              onChange: (value: boolean) => {
                this.params.updateConfig((cfg: ExperimentalConfig) => {
                  cfg.aiListWarnList = value;
                });
              }
            })
            Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
            PlaybackSelectRow({
              title: $r('app.string.yt_exp_ai_sync'),
              options: this.syncOptions(),
              selectedIndex: this.syncIndex(),
              fontColor: this.themePrimary,
              transparentBackground: true,
              onChange: (index: number) => {
                const days = EXP_AILIST_SYNC_DAYS_VALUES[index] ?? 1;
                this.params.updateConfig((cfg: ExperimentalConfig) => {
                  cfg.aiListSyncDays = days;
                });
              }
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
        }
        .padding({ left: 16, right: 16 })

        ListItem() {
          Column({ space: 0 }) {
            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text($r('app.string.yt_exp_ai_status_label'))
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.yourtube_text_primary'))
                Text(this.statusText())
                  .fontSize(12)
                  .fontColor(this.status.error.length > 0
                    ? $r('app.color.yourtube_text_primary')
                    : $r('app.color.yourtube_text_quaternary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Button($r('app.string.yt_exp_ai_sync_now'))
                .fontSize(12)
                .height(32)
                .padding({ left: 12, right: 12 })
                .backgroundColor(this.themePrimary)
                .fontColor($r('app.color.yourtube_text_inverse'))
                .enabled(!this.status.syncing)
                .onClick(() => this.syncNow())
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }
          .width('100%')
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
        }
        .padding({ left: 16, right: 16 })

        ListItem() {
          Column() {
            OptionItem({
              icon: $r('sys.symbol.arrow_counterclockwise'),
              title: $r('app.string.yt_exp_clear_cache'),
              iconColor: this.themePrimary,
              transparentBackground: true,
              showChevron: false,
              onClickAction: () => this.clearCache()
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
        }
        .padding({ left: 16, right: 16, top: 8 })
      }

      ListItem() {
        Text($r('app.string.yt_exp_ai_license'))
          .fontSize(11)
          .fontColor($r('app.color.yourtube_text_disabled'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: 24, right: 24, top: 16, bottom: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: 4 })
  }
}
