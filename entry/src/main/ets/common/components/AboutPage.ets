import { UIConfig } from '../AppState';
import { customAnimationUtil } from '../AnimationUtil';
import { OptionItem } from './OptionItem';
import { pasteboard } from '@kit.BasicServicesKit';
import { HdsNavigation, HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { buildYourTubeTitleBar } from './HdsTitleBar';
import { AppLog } from '../AppLog';

const APP_VERSION = '0.5.5';
const APP_BUILD = '1000014';
const logger = AppLog.getInstance('AboutPage');

// ─── 数据 ──────────────────────────────────────────────────────────────────────

interface OpenSourceItem {
  name: string;
  desc: Resource;
  license: string;
}

interface ChangelogEntry {
  version: string;
  date: string;
  changes: Resource[];
}

const OPEN_SOURCE_ITEMS: OpenSourceItem[] = [
  { name: 'NewPipe', desc: $r('app.string.yt_about_oss_newpipe_desc'), license: 'GPL-3.0' },
  { name: 'iPlay', desc: $r('app.string.yt_about_oss_iplay_desc'), license: 'MIT' },
  { name: 'yt-dlp', desc: $r('app.string.yt_about_oss_ytdlp_desc'), license: 'Unlicense' },
  { name: 'FinVideo', desc: $r('app.string.yt_about_oss_finvideo_desc'), license: 'GPL-3.0' },
  { name: '华为开发者案例', desc: $r('app.string.yt_about_oss_hmsamples_desc'), license: '参考' },
];

const AI_MODELS: string[] = [
  'Kimi k2.6',
  'Deepseek v4 pro',
  'Google Gemini 3.1',
  'Claude Sonnet 4.7',
  'GPT 5.5',
];

const CHANGELOG: ChangelogEntry[] = [
  {
    version: '0.5.5', date: '2026-07-16',
    changes: [
      $r('app.string.yt_changelog_0_5_5_1'),
      $r('app.string.yt_changelog_0_5_5_2'),
      $r('app.string.yt_changelog_0_5_5_3'),
      $r('app.string.yt_changelog_0_5_5_4'),
      $r('app.string.yt_changelog_0_5_5_5'),
      $r('app.string.yt_changelog_0_5_5_6'),
      $r('app.string.yt_changelog_0_5_5_7'),
      $r('app.string.yt_changelog_0_5_5_8'),
    ],
  },
  {
    version: '0.5.4', date: '2026-07-15',
    changes: [
      $r('app.string.yt_changelog_0_5_4_1'),
      $r('app.string.yt_changelog_0_5_4_2'),
      $r('app.string.yt_changelog_0_5_4_3'),
      $r('app.string.yt_changelog_0_5_4_4'),
      $r('app.string.yt_changelog_0_5_4_5'),
      $r('app.string.yt_changelog_0_5_4_6'),
      $r('app.string.yt_changelog_0_5_4_7'),
      $r('app.string.yt_changelog_0_5_4_8'),
    ],
  },
  {
    version: '0.5.3', date: '2026-07-14',
    changes: [
      $r('app.string.yt_changelog_0_5_3_1'),
      $r('app.string.yt_changelog_0_5_3_2'),
      $r('app.string.yt_changelog_0_5_3_3'),
      $r('app.string.yt_changelog_0_5_3_4'),
      $r('app.string.yt_changelog_0_5_3_5'),
      $r('app.string.yt_changelog_0_5_3_6'),
      $r('app.string.yt_changelog_0_5_3_7'),
      $r('app.string.yt_changelog_0_5_3_8'),
    ],
  },
  {
    version: '0.5.2', date: '2026-07-13',
    changes: [
      $r('app.string.yt_changelog_0_5_2_1'),
      $r('app.string.yt_changelog_0_5_2_2'),
      $r('app.string.yt_changelog_0_5_2_3'),
      $r('app.string.yt_changelog_0_5_2_4'),
      $r('app.string.yt_changelog_0_5_2_5'),
      $r('app.string.yt_changelog_0_5_2_6'),
      $r('app.string.yt_changelog_0_5_2_7'),
      $r('app.string.yt_changelog_0_5_2_8'),
    ],
  },
  {
    version: '0.5.1', date: '2026-06-23',
    changes: [
      $r('app.string.yt_changelog_0_5_1_1'),
      $r('app.string.yt_changelog_0_5_1_2'),
      $r('app.string.yt_changelog_0_5_1_3'),
      $r('app.string.yt_changelog_0_5_1_4'),
      $r('app.string.yt_changelog_0_5_1_5'),
      $r('app.string.yt_changelog_0_5_1_6'),
    ],
  },
  {
    version: '0.5.0', date: '2026-06-18',
    changes: [
      $r('app.string.yt_changelog_0_5_0_1'),
      $r('app.string.yt_changelog_0_5_0_2'),
      $r('app.string.yt_changelog_0_5_0_3'),
      $r('app.string.yt_changelog_0_5_0_4'),
      $r('app.string.yt_changelog_0_5_0_5'),
      $r('app.string.yt_changelog_0_5_0_6'),
      $r('app.string.yt_changelog_0_5_0_7'),
      $r('app.string.yt_changelog_0_5_0_8'),
    ],
  },
  {
    version: '0.4.1', date: '2026-05-30',
    changes: [
      $r('app.string.yt_changelog_0_4_1_1'),
      $r('app.string.yt_changelog_0_4_1_2'),
      $r('app.string.yt_changelog_0_4_1_3'),
      $r('app.string.yt_changelog_0_4_1_4'),
      $r('app.string.yt_changelog_0_4_1_5'),
      $r('app.string.yt_changelog_0_4_1_6'),
      $r('app.string.yt_changelog_0_4_1_7'),
      $r('app.string.yt_changelog_0_4_1_8'),
    ],
  },
  {
    version: '0.4.0', date: '2026-05-25',
    changes: [
      $r('app.string.yt_changelog_0_4_0_1'),
      $r('app.string.yt_changelog_0_4_0_2'),
      $r('app.string.yt_changelog_0_4_0_3'),
      $r('app.string.yt_changelog_0_4_0_4'),
    ],
  },
  {
    version: '0.3.1', date: '2026-05-22',
    changes: [
      $r('app.string.yt_changelog_0_3_1_1'),
      $r('app.string.yt_changelog_0_3_1_2'),
      $r('app.string.yt_changelog_0_3_1_3'),
      $r('app.string.yt_changelog_0_3_1_4'),
      $r('app.string.yt_changelog_0_3_1_5'),
      $r('app.string.yt_changelog_0_3_1_6'),
      $r('app.string.yt_changelog_0_3_1_7'),
    ],
  },
  {
    version: '0.3.0', date: '2026-05-18',
    changes: [
      $r('app.string.yt_changelog_0_3_0_1'),
      $r('app.string.yt_changelog_0_3_0_2'),
      $r('app.string.yt_changelog_0_3_0_3'),
      $r('app.string.yt_changelog_0_3_0_4'),
      $r('app.string.yt_changelog_0_3_0_5'),
      $r('app.string.yt_changelog_0_3_0_6'),
      $r('app.string.yt_changelog_0_3_0_7'),
    ],
  },
  {
    version: '0.2.0', date: '2026-05-01',
    changes: [
      $r('app.string.yt_changelog_0_2_0_1'),
      $r('app.string.yt_changelog_0_2_0_2'),
      $r('app.string.yt_changelog_0_2_0_3'),
      $r('app.string.yt_changelog_0_2_0_4'),
      $r('app.string.yt_changelog_0_2_0_5'),
      $r('app.string.yt_changelog_0_2_0_6'),
      $r('app.string.yt_changelog_0_2_0_7'),
      $r('app.string.yt_changelog_0_2_0_8'),
    ],
  },
  {
    version: '0.1.2', date: '2026-04-27',
    changes: [
      $r('app.string.yt_changelog_0_1_2_1'),
      $r('app.string.yt_changelog_0_1_2_2'),
      $r('app.string.yt_changelog_0_1_2_3'),
      $r('app.string.yt_changelog_0_1_2_4'),
      $r('app.string.yt_changelog_0_1_2_5'),
      $r('app.string.yt_changelog_0_1_2_6'),
    ],
  },
  {
    version: '0.1.1', date: '2026-04-25',
    changes: [
      $r('app.string.yt_changelog_0_1_1_1'),
      $r('app.string.yt_changelog_0_1_1_2'),
      $r('app.string.yt_changelog_0_1_1_3'),
      $r('app.string.yt_changelog_0_1_1_4'),
      $r('app.string.yt_changelog_0_1_1_5'),
    ],
  },
  {
    version: '0.1.0', date: '2026-04-23',
    changes: [
      $r('app.string.yt_changelog_0_1_0_1'),
      $r('app.string.yt_changelog_0_1_0_2'),
      $r('app.string.yt_changelog_0_1_0_3'),
      $r('app.string.yt_changelog_0_1_0_4'),
      $r('app.string.yt_changelog_0_1_0_5'),
    ],
  },
];

// ─── 共用：子页面顶部返回栏 ────────────────────────────────────────────────────

@Component
struct SubPageHeader {
  title: ResourceStr = '';
  onBack: () => void = () => {};
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();

  build() {
    Row() {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.arrow_left'))
          .fontSize(22)
          .fontColor([$r('app.color.yourtube_text_primary')])
          .fontWeight(FontWeight.Medium)
      }
      .width(40).height(40)
      .backgroundColor(Color.Transparent)
      .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
      .onClick(() => this.onBack())
      .margin({ right: 8 })

      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.yourtube_text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 8, right: 48, top: 16, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }
}

// ─── 子页面：开源项目 ──────────────────────────────────────────────────────────

@Component
struct OpenSourcePage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  onBack: () => void = () => {};
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();

  build() {
    Column() {
      Scroll() {
        Column({ space: 8 }) {
          ForEach(OPEN_SOURCE_ITEMS, (item: OpenSourceItem) => {
            Column({ space: 6 }) {
              Row() {
                Text(item.name)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.yourtube_text_primary'))
                  .layoutWeight(1)
                Text(item.license)
                  .fontSize(11)
                  .fontColor(this.themePrimary)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .borderRadius(6)
                  .backgroundColor('#1AD32F2F')
              }
              .width('100%').alignItems(VerticalAlign.Center)

              Text(item.desc)
                .fontSize(13)
                .fontColor($r('app.color.yourtube_text_quaternary'))
                .lineHeight(20)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .borderRadius(12)
            .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          }, (item: OpenSourceItem) => item.name)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .width('100%').layoutWeight(1)
      .clip(false)
      .edgeEffect(EdgeEffect.Spring).scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%').height('100%')
    .padding({ top: 56 })
    .backgroundColor(Color.Transparent)
  }
}

// ─── 子页面：AI 模型 ───────────────────────────────────────────────────────────

@Component
struct AiModelsPage {
  onBack: () => void = () => {};
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();

  build() {
    Column() {
      Column({ space: 0 }) {
        ForEach(AI_MODELS, (model: string, index: number) => {
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.star_fill'))
              .fontSize(16)
              .fontColor(['#8B5CF6'])
            Text(model)
              .fontSize(15)
              .fontColor($r('app.color.yourtube_text_primary'))
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 16, bottom: 16, left: 16, right: 16 })
          .alignItems(VerticalAlign.Center)

          if (index < AI_MODELS.length - 1) {
            Divider().color($r('sys.color.comp_divider')).margin({ left: 16 })
          }
        }, (model: string) => model)
      }
      .width('100%')
      .borderRadius(12)
      .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
      .margin({ left: 16, right: 16, top: 8 })
    }
    .width('100%').height('100%')
    .padding({ top: 56 })
    .backgroundColor(Color.Transparent)
  }
}

// ─── 子页面：更新日志 ──────────────────────────────────────────────────────────

@Component
struct ChangelogPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  onBack: () => void = () => {};

  build() {
    Column() {
      Scroll() {
        Column({ space: 10 }) {
          ForEach(CHANGELOG, (item: ChangelogEntry, index: number) => {
            Column({ space: 0 }) {
              // 版本标题行
              Row({ space: 8 }) {
                Text(`v${item.version}`)
                  .fontSize(15).fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.yourtube_text_primary'))
                if (index === 0) {
                  Text($r('app.string.yt_about_current_version'))
                    .fontSize(10)
                    .fontColor(this.themePrimary)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(4)
                    .backgroundColor('#1AD32F2F')
                }
                Blank()
                Text(item.date)
                  .fontSize(12).fontColor($r('app.color.yourtube_text_hint'))
              }
              .width('100%').alignItems(VerticalAlign.Center).margin({ bottom: 10 })

              ForEach(item.changes, (change: Resource) => {
                Row({ space: 8 }) {
                  Text('·').fontSize(16).fontColor(this.themePrimary).width(12)
                  Text(change)
                    .fontSize(13).fontColor($r('app.color.yourtube_text_secondary'))
                    .layoutWeight(1).lineHeight(20)
                }
                .width('100%').alignItems(VerticalAlign.Top).padding({ bottom: 5 })
              }, (_change: Resource, changeIndex: number) => `${item.version}-${changeIndex}`)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .borderRadius(12)
            .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
            .border(index === 0 ? { width: 1, color: this.themePrimary, radius: 12 } : { width: 0 })
          }, (item: ChangelogEntry) => item.version)
        }
        .width('100%').padding({ left: 16, right: 16, bottom: 24 })
      }
      .width('100%').layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring).scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%').height('100%')
    .padding({ top: 56 })
    .backgroundColor(Color.Transparent)
  }
}

// ─── 主页面 ────────────────────────────────────────────────────────────────────

@Component
export struct AboutPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  onBack?: () => void;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @State private aboutNavStack: NavPathStack = new NavPathStack();
  private aboutScroller: Scroller = new Scroller();

  private copyToClipboard(text: string): void {
    const pasteboardData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    const systemPasteboard = pasteboard.getSystemPasteboard();
    systemPasteboard.setData(pasteboardData).then(() => {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.yt_toast_copied'), duration: 2000 });
      logger.info(`copy succeeded value=${text}`);
    }).catch((error: Error) => {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.yt_toast_copy_failed'), duration: 2000 });
      logger.error(`copy failed error=${error.message}`);
    });
  }

  // 根据导航名称渲染子页面
  @Builder
  aboutPageBuilder(name: string) {
    if (name === 'open_source') {
      HdsNavDestination() {
        OpenSourcePage({ onBack: () => { this.aboutNavStack.pop(); } })
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(buildYourTubeTitleBar({
        title: $r('app.string.yt_about_open_source'),
        onBack: () => {
          this.aboutNavStack.pop();
        }
      }))
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .onBackPressed(() => { this.aboutNavStack.pop(); return true; })
    } else if (name === 'ai_models') {
      HdsNavDestination() {
        AiModelsPage({ onBack: () => { this.aboutNavStack.pop(); } })
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(buildYourTubeTitleBar({
        title: $r('app.string.yt_about_ai_models'),
        onBack: () => {
          this.aboutNavStack.pop();
        }
      }))
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .onBackPressed(() => { this.aboutNavStack.pop(); return true; })
    } else if (name === 'changelog') {
      HdsNavDestination() {
        ChangelogPage({ onBack: () => { this.aboutNavStack.pop(); } })
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(buildYourTubeTitleBar({
        title: $r('app.string.yt_about_changelog'),
        onBack: () => {
          this.aboutNavStack.pop();
        }
      }))
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .onBackPressed(() => { this.aboutNavStack.pop(); return true; })
    }
  }

  // 关于主页内容
  @Builder
  MainContent() {
    Column() {
      Scroll(this.aboutScroller) {
        Column({ space: 0 }) {
          // ── App 身份区 ──────────────────────────────────────
          Column({ space: 14 }) {
            Image($r('app.media.app_icon'))
              .width(72)
              .height(72)
              .objectFit(ImageFit.Cover)
              .borderRadius(16)
              .shadow({ radius: 12, color: '#22000000', offsetX: 0, offsetY: 4 })

            Column({ space: 4 }) {
              Text('YourPipe')
                .fontSize(26).fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.yourtube_text_primary'))
              Text(`${getContext().resourceManager.getStringSync($r('app.string.yt_label_version_format').id)} ${APP_VERSION}`)
                .fontSize(13).fontColor($r('app.color.yourtube_text_hint'))
            }
            .alignItems(HorizontalAlign.Center)

            Text($r('app.string.yt_about_description'))
              .fontSize(13)
              .fontColor($r('app.color.yourtube_text_quaternary'))
              .textAlign(TextAlign.Center)
              .lineHeight(21)

            // ── 社群 ──
            Column({ space: 8 }) {
              // 应用包名
              Row({ space: 10 }) {
                Text('ID')
                  .fontSize(13).fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.yourtube_text_inverse'))
                  .width(32).height(32)
                  .textAlign(TextAlign.Center)
                  .borderRadius(8)
                  .backgroundColor(this.themePrimary)
                Column({ space: 2 }) {
                  Text($r('app.string.yt_about_package_name'))
                    .fontSize(13).fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.yourtube_text_primary'))
                  Text('com.talon.yourpipe')
                    .fontSize(12).fontColor($r('app.color.yourtube_text_hint'))
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(14).fontColor([$r('app.color.yourtube_text_hint')])
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .borderRadius(12)
              .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
              .alignItems(VerticalAlign.Center)
              .onClick(() => this.copyToClipboard('com.talon.yourpipe'))

              // QQ 群
              Row({ space: 10 }) {
                Text('QQ')
                  .fontSize(13).fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.yourtube_text_inverse'))
                  .width(32).height(32)
                  .textAlign(TextAlign.Center)
                  .borderRadius(8)
                  .backgroundColor('#12B7F5')
                Column({ space: 2 }) {
                  Text($r('app.string.yt_about_qq_group'))
                    .fontSize(13).fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.yourtube_text_primary'))
                  Text('2167068947')
                    .fontSize(12).fontColor($r('app.color.yourtube_text_hint'))
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(14).fontColor([$r('app.color.yourtube_text_hint')])
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .borderRadius(12)
              .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
              .alignItems(VerticalAlign.Center)
              .onClick(() => this.copyToClipboard('2167068947'))

              // Telegram
              Row({ space: 10 }) {
                Text('TG')
                  .fontSize(13).fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.yourtube_text_inverse'))
                  .width(32).height(32)
                  .textAlign(TextAlign.Center)
                  .borderRadius(8)
                  .backgroundColor('#2AABEE')
                Column({ space: 2 }) {
                  Text($r('app.string.yt_about_tg_group'))
                    .fontSize(13).fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.yourtube_text_primary'))
                  Text('t.me/yourpipegroup')
                    .fontSize(12).fontColor($r('app.color.yourtube_text_hint'))
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(14).fontColor([$r('app.color.yourtube_text_hint')])
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .borderRadius(12)
              .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
              .alignItems(VerticalAlign.Center)
              .onClick(() => this.copyToClipboard('t.me/yourpipegroup'))
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 20, bottom: 24, left: 20, right: 20 })

          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ left: 16, right: 16, bottom: 6 })

          // ── 子页面入口列表 ──────────────────────────────────
          Column({ space: 6 }) {
            // 分节标题
            Row() {
              Text($r('app.string.yt_about_project_info'))
                .fontSize(13).fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.yourtube_text_secondary'))
                .letterSpacing(0.5)
            }
            .width('100%').padding({ left: 4, top: 8, bottom: 4 })

            OptionItem({
              icon: $r('sys.symbol.translate'),
              title: $r('app.string.yt_about_open_source'),
              subtitle: `${OPEN_SOURCE_ITEMS.length} ${getContext().resourceManager.getStringSync($r('app.string.yt_label_projects').id)}`,
              iconColor: $r('app.color.yourtube_option_icon_language'),
              onClickAction: () => { this.aboutNavStack.pushPathByName('open_source', null); }
            })

            OptionItem({
              icon: $r('sys.symbol.star_fill'),
              title: $r('app.string.yt_about_ai_models'),
              subtitle: `${AI_MODELS.length} ${getContext().resourceManager.getStringSync($r('app.string.yt_label_models').id)}`,
              iconColor: '#8B5CF6',
              onClickAction: () => { this.aboutNavStack.pushPathByName('ai_models', null); }
            })

            OptionItem({
              icon: $r('sys.symbol.clock'),
              title: $r('app.string.yt_about_changelog'),
              subtitle: `${getContext().resourceManager.getStringSync($r('app.string.yt_label_latest_version').id)}${CHANGELOG[0].version}`,
              iconColor: $r('app.color.yourtube_option_icon_palette'),
              onClickAction: () => { this.aboutNavStack.pushPathByName('changelog', null); }
            })
          }
          .width('100%').padding({ left: 16, right: 16 })

          // ── 底部版权 ──
          Column() {
            Text(`YourPipe v${APP_VERSION}  ·  GPL-3.0`)
              .fontSize(11).fontColor($r('app.color.yourtube_text_disabled'))
            Text('© 2025 Talon')
              .fontSize(11).fontColor($r('app.color.yourtube_text_disabled'))
              .margin({ top: 2 })
          }
          .width('100%').padding({ top: 20, bottom: 36 })
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
      }
      .width('100%').layoutWeight(1)
      .clip(false)
      .edgeEffect(EdgeEffect.Spring).scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%').height('100%')
    .padding({ top: 56 })
    .backgroundColor(Color.Transparent)
  }

  build() {
    HdsNavigation(this.aboutNavStack) {
      this.MainContent()
    }
    .navDestination(this.aboutPageBuilder)
    .bindToScrollable([this.aboutScroller])
    .titleMode(HdsNavigationTitleMode.MINI)
    .titleBar(buildYourTubeTitleBar({
      title: $r('app.string.yt_option_about'),
      onBack: () => {
        if (this.onBack) {
          this.onBack();
        }
      }
    }))
    .hideToolBar(true)
    .mode(NavigationMode.Stack)
    .width('100%').height('100%')
    .backgroundColor(Color.Transparent)
  }
}
