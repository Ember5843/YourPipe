import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import { ExperimentalConfig } from '../../common/experimental/ExperimentalConfig';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('OptionsHeatmapPage');

interface HeatmapPageParams {
  updateConfig: (mutator: (cfg: ExperimentalConfig) => void) => void;
}

@Component
export struct OptionsHeatmapPage {
  @StorageLink('experimentalConfig') cfg: ExperimentalConfig = new ExperimentalConfig();
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop params: HeatmapPageParams = {
    updateConfig: () => {}
  };

  build() {
    List({ space: 6 }) {
      ListItem() {
        Text($r('app.string.yt_exp_hm_desc'))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_hint'))
          .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      }

      ListItem() {
        Column() {
          PlaybackToggleRow({
            title: $r('app.string.yt_exp_hm_title'),
            isOn: this.cfg.heatmapPluginEnabled,
            themeColor: this.themePrimary,
            transparentBackground: true,
            onChange: (value: boolean) => {
              logger.info(`heatmap plugin master=${value}`);
              this.params.updateConfig((cfg: ExperimentalConfig) => {
                cfg.heatmapPluginEnabled = value;
              });
            }
          })
        }
        .width('100%')
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
      }
      .padding({ left: 16, right: 16 })

      if (this.cfg.heatmapPluginEnabled) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_exp_hm_title') })
        }
        .padding({ left: 16, right: 16, top: 8 })

        ListItem() {
          Column() {
            PlaybackToggleRow({
              title: $r('app.string.yt_exp_hm_show_graph'),
              subtitle: $r('app.string.yt_exp_hm_show_graph_desc'),
              isOn: this.cfg.heatmapShowGraph,
              themeColor: this.themePrimary,
              transparentBackground: true,
              onChange: (value: boolean) => {
                this.params.updateConfig((cfg: ExperimentalConfig) => {
                  cfg.heatmapShowGraph = value;
                });
              }
            })
            Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
            PlaybackToggleRow({
              title: $r('app.string.yt_exp_hm_jump_ahead'),
              subtitle: $r('app.string.yt_exp_hm_jump_ahead_desc'),
              isOn: this.cfg.heatmapJumpAhead,
              themeColor: this.themePrimary,
              transparentBackground: true,
              onChange: (value: boolean) => {
                this.params.updateConfig((cfg: ExperimentalConfig) => {
                  cfg.heatmapJumpAhead = value;
                });
              }
            })
          }
          .width('100%')
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
        }
        .padding({ left: 16, right: 16 })
      }

      ListItem() {
        Text($r('app.string.yt_exp_hm_footer'))
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
