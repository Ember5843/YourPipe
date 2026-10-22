import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { OptionItem } from '../../common/components/OptionItem';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import {
  ExperimentalConfig,
  EXP_SB_BEHAVIORS,
  EXP_SB_BEHAVIOR_TOAST,
  EXP_SPONSOR_CATEGORIES,
  EXP_UNSKIP_SECONDS_VALUES
} from '../../common/experimental/ExperimentalConfig';
import { SponsorBlockClient } from '../../common/experimental/SponsorBlockClient';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('OptionsSponsorBlockPage');

interface SponsorBlockPageParams {
  updateConfig: (mutator: (cfg: ExperimentalConfig) => void) => void;
}

@Component
export struct OptionsSponsorBlockPage {
  @StorageLink('experimentalConfig') cfg: ExperimentalConfig = new ExperimentalConfig();
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop params: SponsorBlockPageParams = {
    updateConfig: () => {}
  };

  private categoryLabel(category: string): Resource {
    switch (category) {
      case 'sponsor': return $r('app.string.yt_exp_sb_cat_sponsor');
      case 'selfpromo': return $r('app.string.yt_exp_sb_cat_selfpromo');
      case 'interaction': return $r('app.string.yt_exp_sb_cat_interaction');
      case 'intro': return $r('app.string.yt_exp_sb_cat_intro');
      case 'outro': return $r('app.string.yt_exp_sb_cat_outro');
      case 'preview': return $r('app.string.yt_exp_sb_cat_preview');
      case 'music_offtopic': return $r('app.string.yt_exp_sb_cat_music');
      case 'filler': return $r('app.string.yt_exp_sb_cat_filler');
      case 'poi_highlight': return $r('app.string.yt_exp_sb_cat_highlight');
      default: return $r('app.string.yt_exp_sb_categories');
    }
  }

  private behaviorOptions(): SelectOption[] {
    return [
      { value: $r('app.string.yt_exp_sb_behavior_toast') } as SelectOption,
      { value: $r('app.string.yt_exp_sb_behavior_silent') } as SelectOption,
      { value: $r('app.string.yt_exp_sb_behavior_manual') } as SelectOption
    ];
  }

  private behaviorIndex(): number {
    const index = EXP_SB_BEHAVIORS.indexOf(this.cfg.sponsorBehavior);
    return index >= 0 ? index : 0;
  }

  private unskipOptions(): SelectOption[] {
    const rm = getContext().resourceManager;
    return EXP_UNSKIP_SECONDS_VALUES.map((seconds: number) => {
      return {
        value: rm.getStringSync($r('app.string.yt_exp_sb_unskip_value').id, seconds)
      } as SelectOption;
    });
  }

  private unskipIndex(): number {
    const index = EXP_UNSKIP_SECONDS_VALUES.indexOf(this.cfg.sponsorUnskipSeconds);
    return index >= 0 ? index : 1;
  }

  private clearCache(): void {
    SponsorBlockClient.getInstance().clearCache();
    logger.info('sponsorblock cache cleared by user');
    this.getUIContext().getPromptAction().showToast({
      message: $r('app.string.yt_exp_cache_cleared'),
      duration: 2000
    });
  }

  build() {
    List({ space: 6 }) {
      ListItem() {
        Text($r('app.string.yt_exp_sb_desc'))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_hint'))
          .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      }

      ListItem() {
        Column() {
          PlaybackToggleRow({
            title: $r('app.string.yt_exp_sb_master'),
            isOn: this.cfg.sponsorBlockEnabled,
            themeColor: this.themePrimary,
            transparentBackground: true,
            onChange: (value: boolean) => {
              logger.info(`sponsorblock master=${value}`);
              this.params.updateConfig((cfg: ExperimentalConfig) => {
                cfg.sponsorBlockEnabled = value;
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

      if (this.cfg.sponsorBlockEnabled) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_exp_sb_categories') })
        }
        .padding({ left: 16, right: 16, top: 8 })

        ListItem() {
          Column() {
            ForEach(EXP_SPONSOR_CATEGORIES, (category: string, index: number) => {
              if (index > 0) {
                Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
              }
              PlaybackToggleRow({
                title: this.categoryLabel(category),
                isOn: this.cfg.isSponsorCategoryEnabled(category),
                themeColor: this.themePrimary,
                transparentBackground: true,
                onChange: (value: boolean) => {
                  this.params.updateConfig((cfg: ExperimentalConfig) => {
                    cfg.setSponsorCategoryEnabled(category, value);
                  });
                  logger.info(`category=${category} enabled=${value}`);
                }
              })
            }, (category: string) => category)
          }
          .width('100%')
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
        }
        .padding({ left: 16, right: 16 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_exp_sb_behavior') })
        }
        .padding({ left: 16, right: 16, top: 8 })

        ListItem() {
          Column() {
            PlaybackSelectRow({
              title: $r('app.string.yt_exp_sb_behavior'),
              options: this.behaviorOptions(),
              selectedIndex: this.behaviorIndex(),
              fontColor: this.themePrimary,
              transparentBackground: true,
              onChange: (index: number) => {
                const behavior = EXP_SB_BEHAVIORS[index] || EXP_SB_BEHAVIOR_TOAST;
                this.params.updateConfig((cfg: ExperimentalConfig) => {
                  cfg.sponsorBehavior = behavior;
                });
                logger.info(`behavior=${behavior}`);
              }
            })
            Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
            PlaybackSelectRow({
              title: $r('app.string.yt_exp_sb_unskip'),
              options: this.unskipOptions(),
              selectedIndex: this.unskipIndex(),
              fontColor: this.themePrimary,
              transparentBackground: true,
              onChange: (index: number) => {
                const seconds = EXP_UNSKIP_SECONDS_VALUES[index] || 5;
                this.params.updateConfig((cfg: ExperimentalConfig) => {
                  cfg.sponsorUnskipSeconds = seconds;
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
            PlaybackToggleRow({
              title: $r('app.string.yt_exp_sb_privacy'),
              subtitle: $r('app.string.yt_exp_sb_privacy_desc'),
              isOn: this.cfg.sponsorPrivacyMode,
              themeColor: this.themePrimary,
              transparentBackground: true,
              onChange: (value: boolean) => {
                this.params.updateConfig((cfg: ExperimentalConfig) => {
                  cfg.sponsorPrivacyMode = value;
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
        Text($r('app.string.yt_exp_footer'))
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

