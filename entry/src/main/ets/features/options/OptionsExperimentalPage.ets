import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import { ExperimentalConfig } from '../../common/experimental/ExperimentalConfig';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('OptionsExperimentalPage');

interface ExperimentalPageParams {
  onNavigate: (name: string) => void;
  updateConfig: (mutator: (cfg: ExperimentalConfig) => void) => void;
}

/**
 * 设置 → 实验性功能：三个内置增强模块的统一入口。
 * 列表页只负责开关与状态，具体参数在各自的设置页。
 */
@Component
export struct OptionsExperimentalPage {
  @StorageLink('experimentalConfig') cfg: ExperimentalConfig = new ExperimentalConfig();
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop params: ExperimentalPageParams = {
    onNavigate: () => {},
    updateConfig: () => {}
  };

  private sponsorSubtitle(): string {
    const state = this.cfg.sponsorBlockEnabled
      ? getContext().resourceManager.getStringSync($r('app.string.yt_exp_enabled').id)
      : getContext().resourceManager.getStringSync($r('app.string.yt_exp_disabled').id);
    const count = this.cfg.enabledSponsorCategories().length;
    const detail = getContext().resourceManager.getStringSync(
      $r('app.string.yt_exp_sb_categories_count').id, count);
    return `${state} · ${detail}`;
  }

  private simpleStateSubtitle(enabled: boolean): string {
    return enabled
      ? getContext().resourceManager.getStringSync($r('app.string.yt_exp_enabled').id)
      : getContext().resourceManager.getStringSync($r('app.string.yt_exp_disabled').id);
  }

  @Builder
  PluginRow(icon: Resource, title: ResourceStr, subtitle: string, enabled: boolean,
    onChange: (value: boolean) => void, onOpen: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([this.themePrimary])
        .width(32)

      Column({ space: 4 }) {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.yourtube_text_primary'))
        Text(subtitle)
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => onOpen())

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([$r('app.color.yourtube_icon_hint')])

      Toggle({ type: ToggleType.Switch, isOn: enabled })
        .selectedColor(this.themePrimary)
        .onChange((value: boolean) => onChange(value))
    }
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  build() {
    List({ space: 6 }) {
      ListItem() {
        Text($r('app.string.yt_exp_subtitle'))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_hint'))
          .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      }

      ListItem() {
        Column({ space: 0 }) {
          this.PluginRow(
            $r('sys.symbol.clock'),
            $r('app.string.yt_exp_sb_title'),
            this.sponsorSubtitle(),
            this.cfg.sponsorBlockEnabled,
            (value: boolean) => {
              logger.info(`sponsorblock toggle enabled=${value}`);
              this.params.updateConfig((cfg: ExperimentalConfig) => {
                cfg.sponsorBlockEnabled = value;
              });
            },
            () => this.params.onNavigate('experimental_sponsorblock')
          )
          Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
          this.PluginRow(
            $r('sys.symbol.star_fill'),
            $r('app.string.yt_exp_da_title'),
            this.simpleStateSubtitle(this.cfg.deArrowEnabled),
            this.cfg.deArrowEnabled,
            (value: boolean) => {
              logger.info(`dearrow toggle enabled=${value}`);
              this.params.updateConfig((cfg: ExperimentalConfig) => {
                cfg.deArrowEnabled = value;
              });
            },
            () => this.params.onNavigate('experimental_dearrow')
          )
          Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
          this.PluginRow(
            $r('sys.symbol.doc_plaintext'),
            $r('app.string.yt_exp_ai_title'),
            this.simpleStateSubtitle(this.cfg.aiListEnabled),
            this.cfg.aiListEnabled,
            (value: boolean) => {
              logger.info(`ailist toggle enabled=${value}`);
              this.params.updateConfig((cfg: ExperimentalConfig) => {
                cfg.aiListEnabled = value;
              });
            },
            () => this.params.onNavigate('experimental_ailist')
          )
        }
        .width('100%')
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
      }
      .padding({ left: 16, right: 16 })

      ListItem() {
        Column({ space: 4 }) {
          Text($r('app.string.yt_exp_footer'))
            .fontSize(11)
            .fontColor($r('app.color.yourtube_text_disabled'))
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .padding({ left: 24, right: 24, top: 16, bottom: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: 4 })
  }
}

