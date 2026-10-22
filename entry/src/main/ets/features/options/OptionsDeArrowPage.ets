import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { OptionItem } from '../../common/components/OptionItem';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import {
  ExperimentalConfig,
  EXP_DEARROW_CONCURRENCY_VALUES,
  EXP_DEARROW_LIMIT_VALUES
} from '../../common/experimental/ExperimentalConfig';
import { DeArrowClient } from '../../common/experimental/DeArrowClient';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('OptionsDeArrowPage');

interface DeArrowPageParams {
  updateConfig: (mutator: (cfg: ExperimentalConfig) => void) => void;
}

@Component
export struct OptionsDeArrowPage {
  @StorageLink('experimentalConfig') cfg: ExperimentalConfig = new ExperimentalConfig();
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop params: DeArrowPageParams = {
    updateConfig: () => {}
  };

  private limitOptions(): SelectOption[] {
    return EXP_DEARROW_LIMIT_VALUES.map((value: number) => {
      return { value: value.toString() } as SelectOption;
    });
  }

  private limitIndex(): number {
    const index = EXP_DEARROW_LIMIT_VALUES.indexOf(this.cfg.deArrowLimit);
    return index >= 0 ? index : 1;
  }

  private concurrencyOptions(): SelectOption[] {
    return EXP_DEARROW_CONCURRENCY_VALUES.map((value: number) => {
      return { value: value.toString() } as SelectOption;
    });
  }

  private concurrencyIndex(): number {
    const index = EXP_DEARROW_CONCURRENCY_VALUES.indexOf(this.cfg.deArrowConcurrency);
    return index >= 0 ? index : 1;
  }

  private clearCache(): void {
    DeArrowClient.getInstance().clearCache();
    logger.info('dearrow cache cleared by user');
    this.getUIContext().getPromptAction().showToast({
      message: $r('app.string.yt_exp_cache_cleared'),
      duration: 2000
    });
  }

  build() {
    List({ space: 6 }) {
      ListItem() {
        Text($r('app.string.yt_exp_da_desc'))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_hint'))
          .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      }

      ListItem() {
        Column() {
          PlaybackToggleRow({
            title: $r('app.string.yt_exp_da_title'),
            isOn: this.cfg.deArrowEnabled,
            themeColor: this.themePrimary,
            transparentBackground: true,
            onChange: (value: boolean) => {
              logger.info(`dearrow master=${value}`);
              this.params.updateConfig((cfg: ExperimentalConfig) => {
                cfg.deArrowEnabled = value;
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

      if (this.cfg.deArrowEnabled) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_exp_da_title') })
        }
        .padding({ left: 16, right: 16, top: 8 })

        ListItem() {
          Column() {
            PlaybackToggleRow({
              title: $r('app.string.yt_exp_da_replace_titles'),
              isOn: this.cfg.deArrowTitles,
              themeColor: this.themePrimary,
              transparentBackground: true,
              onChange: (value: boolean) => {
                this.params.updateConfig((cfg: ExperimentalConfig) => {
                  cfg.deArrowTitles = value;
                });
              }
            })
            Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
            PlaybackToggleRow({
              title: $r('app.string.yt_exp_da_thumbs'),
              subtitle: $r('app.string.yt_exp_da_thumbs_desc'),
              isOn: this.cfg.deArrowThumbnails,
              themeColor: this.themePrimary,
              transparentBackground: true,
              onChange: (value: boolean) => {
                this.params.updateConfig((cfg: ExperimentalConfig) => {
                  cfg.deArrowThumbnails = value;
                });
              }
            })
            Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
            PlaybackSelectRow({
              title: $r('app.string.yt_exp_da_limit'),
              options: this.limitOptions(),
              selectedIndex: this.limitIndex(),
              fontColor: this.themePrimary,
              transparentBackground: true,
              onChange: (index: number) => {
                const limit = EXP_DEARROW_LIMIT_VALUES[index] || 20;
                this.params.updateConfig((cfg: ExperimentalConfig) => {
                  cfg.deArrowLimit = limit;
                });
              }
            })
            Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
            PlaybackSelectRow({
              title: $r('app.string.yt_exp_da_concurrency'),
              options: this.concurrencyOptions(),
              selectedIndex: this.concurrencyIndex(),
              fontColor: this.themePrimary,
              transparentBackground: true,
              onChange: (index: number) => {
                const concurrency = EXP_DEARROW_CONCURRENCY_VALUES[index] || 4;
                this.params.updateConfig((cfg: ExperimentalConfig) => {
                  cfg.deArrowConcurrency = concurrency;
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
        Text($r('app.string.yt_exp_da_footer'))
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
