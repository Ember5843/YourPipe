import { UIConfig } from '../AppState';
import { customAnimationUtil } from '../AnimationUtil';
import { OptionItem } from './OptionItem';
import { PlaybackSectionTitle } from './PlaybackSectionTitle';
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { AppLog } from '../AppLog';
import { getAppVersion } from '../AppVersion';
import { ThemeColorUtil } from '../ThemeColorUtil';
import { SECTION_CARD_RADIUS } from './MediaCardTokens';

const GITHUB_REPO_URL = 'https://github.com/Ember5843/YourPipe';
const logger = AppLog.getInstance('AboutPage');

// ─── 数据 ──────────────────────────────────────────────────────────────────────

interface OpenSourceItem {
  name: string;
  desc: Resource;
  license: string;
  icon: Resource;
}

interface AiModelItem {
  name: string;
  icon: Resource;
}

interface ChangelogEntry {
  version: string;
  date: string;
  changes: Resource[];
}

const OPEN_SOURCE_ITEMS: OpenSourceItem[] = [
  {
    name: 'NewPipe',
    desc: $r('app.string.yt_about_oss_newpipe_desc'),
    license: 'GPL-3.0',
    icon: $r('app.media.about_logo_newpipe'),
  },
  {
    name: 'iPlay',
    desc: $r('app.string.yt_about_oss_iplay_desc'),
    license: 'MIT',
    icon: $r('app.media.about_logo_iplay'),
  },
  {
    name: 'yt-dlp',
    desc: $r('app.string.yt_about_oss_ytdlp_desc'),
    license: 'Unlicense',
    icon: $r('app.media.about_logo_ytdlp'),
  },
  {
    name: 'FinVideo',
    desc: $r('app.string.yt_about_oss_finvideo_desc'),
    license: 'GPL-3.0',
    icon: $r('app.media.about_logo_finvideo'),
  },
  {
    name: '华为开发者案例',
    desc: $r('app.string.yt_about_oss_hmsamples_desc'),
    license: '参考',
    icon: $r('app.media.about_logo_hmsamples'),
  },
];

const AI_MODELS: AiModelItem[] = [
  { name: 'Kimi k2.6', icon: $r('app.media.about_logo_kimi') },
  { name: 'Deepseek v4 pro', icon: $r('app.media.about_logo_deepseek') },
  { name: 'Google Gemini 3.1', icon: $r('app.media.about_logo_gemini') },
  { name: 'Claude Sonnet 4.7', icon: $r('app.media.about_logo_claude') },
  { name: 'GPT 5.5', icon: $r('app.media.about_logo_openai') },
];

const CHANGELOG: ChangelogEntry[] = [
  {
    version: '0.5.9', date: '2026-08-25',
    changes: [
      $r('app.string.yt_changelog_0_5_9_1'),
      $r('app.string.yt_changelog_0_5_9_2'),
      $r('app.string.yt_changelog_0_5_9_3'),
      $r('app.string.yt_changelog_0_5_9_4'),
      $r('app.string.yt_changelog_0_5_9_5'),
      $r('app.string.yt_changelog_0_5_9_6'),
      $r('app.string.yt_changelog_0_5_9_7'),
    ],
  },
  {
    version: '0.5.8', date: '2026-08-17',
    changes: [
      $r('app.string.yt_changelog_0_5_8_1'),
      $r('app.string.yt_changelog_0_5_8_2'),
      $r('app.string.yt_changelog_0_5_8_3'),
      $r('app.string.yt_changelog_0_5_8_4'),
      $r('app.string.yt_changelog_0_5_8_5'),
      $r('app.string.yt_changelog_0_5_8_6'),
      $r('app.string.yt_changelog_0_5_8_7'),
    ],
  },
  {
    version: '0.5.7', date: '2026-07-27',
    changes: [
      $r('app.string.yt_changelog_0_5_7_1'),
      $r('app.string.yt_changelog_0_5_7_2'),
      $r('app.string.yt_changelog_0_5_7_3'),
      $r('app.string.yt_changelog_0_5_7_4'),
      $r('app.string.yt_changelog_0_5_7_5'),
      $r('app.string.yt_changelog_0_5_7_6'),
      $r('app.string.yt_changelog_0_5_7_7'),
      $r('app.string.yt_changelog_0_5_7_8'),
    ],
  },
  {
    version: '0.5.6', date: '2026-07-24',
    changes: [
      $r('app.string.yt_changelog_0_5_6_1'),
      $r('app.string.yt_changelog_0_5_6_2'),
      $r('app.string.yt_changelog_0_5_6_3'),
      $r('app.string.yt_changelog_0_5_6_4'),
      $r('app.string.yt_changelog_0_5_6_5'),
      $r('app.string.yt_changelog_0_5_6_6'),
      $r('app.string.yt_changelog_0_5_6_7'),
      $r('app.string.yt_changelog_0_5_6_8'),
    ],
  },
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
export struct OpenSourcePage {

  build() {
    Column() {
      Scroll() {
        Column({ space: 6 }) {
          ForEach(OPEN_SOURCE_ITEMS, (item: OpenSourceItem) => {
            OptionItem({
              imageIcon: item.icon,
              title: item.name,
              subtitle: `${item.license} · ${getContext().resourceManager.getStringSync(item.desc.id)}`,
              showChevron: false,
              subtitleMaxLines: 2,
            })
          }, (item: OpenSourceItem) => item.name)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24, top: 8 })
      }
      .width('100%').layoutWeight(1)
      .clip(false)
      .edgeEffect(EdgeEffect.Spring).scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%').height('100%')
    .backgroundColor(Color.Transparent)
  }
}

// ─── 子页面：AI 模型 ───────────────────────────────────────────────────────────

@Component
export struct AiModelsPage {

  build() {
    Column() {
      Scroll() {
        Column({ space: 6 }) {
          ForEach(AI_MODELS, (model: AiModelItem) => {
            OptionItem({
              imageIcon: model.icon,
              title: model.name,
              showChevron: false,
            })
          }, (model: AiModelItem) => model.name)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24, top: 8 })
      }
      .width('100%').layoutWeight(1)
      .clip(false)
      .edgeEffect(EdgeEffect.Spring).scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%').height('100%')
    .backgroundColor(Color.Transparent)
  }
}

// ─── 子页面：更新日志 ──────────────────────────────────────────────────────────

@Component
export struct ChangelogPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';

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
                    .backgroundColor(ThemeColorUtil.selectedBackground(this.themePrimary))
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
            .borderRadius(SECTION_CARD_RADIUS)
            .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
            .border(index === 0 ? { width: 1, color: this.themePrimary, radius: 16 } : { width: 0 })
          }, (item: ChangelogEntry) => item.version)
        }
        .width('100%').padding({ left: 16, right: 16, bottom: 24, top: 8 })
      }
      .width('100%').layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring).scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%').height('100%')
    .backgroundColor(Color.Transparent)
  }
}

// ─── 主页面 ────────────────────────────────────────────────────────────────────

@Component
export struct AboutPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  onNavigate: (name: string) => void = () => {};
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
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

  private openExternalLink(url: string): void {
    try {
      logger.info(`openExternalLink url=${url}`);
      const context = getContext(this) as common.UIAbilityContext;
      context.openLink(url, { appLinkingOnly: false });
    } catch (e) {
      logger.error(`openExternalLink failed: ${String(e)}`);
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
              Text(`${getContext().resourceManager.getStringSync($r('app.string.yt_label_version_format').id)} ${getAppVersion().versionName}`)
                .fontSize(13).fontColor($r('app.color.yourtube_text_hint'))
            }
            .alignItems(HorizontalAlign.Center)

            Text($r('app.string.yt_about_description'))
              .fontSize(13)
              .fontColor($r('app.color.yourtube_text_quaternary'))
              .textAlign(TextAlign.Center)
              .lineHeight(21)

            // ── 社群 / 标识 ──
            Column({ space: 0 }) {
              OptionItem({
                imageIcon: $r('app.media.app_icon'),
                title: $r('app.string.yt_about_package_name'),
                subtitle: 'com.talon.yourpipe',
                transparentBackground: true,
                onClickAction: () => this.copyToClipboard('com.talon.yourpipe'),
              })
              Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
              OptionItem({
                imageIcon: $r('app.media.about_logo_qq'),
                title: $r('app.string.yt_about_qq_group'),
                subtitle: '2167068947',
                transparentBackground: true,
                onClickAction: () => this.copyToClipboard('2167068947'),
              })
              Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
              OptionItem({
                imageIcon: $r('app.media.about_logo_telegram'),
                title: $r('app.string.yt_about_tg_group'),
                subtitle: 't.me/yourpipegroup',
                transparentBackground: true,
                onClickAction: () => this.copyToClipboard('t.me/yourpipegroup'),
              })
              Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
              OptionItem({
                imageIcon: $r('app.media.about_logo_github'),
                title: $r('app.string.yt_about_github_repo'),
                subtitle: 'github.com/Ember5843/YourPipe',
                transparentBackground: true,
                onClickAction: () => this.openExternalLink(GITHUB_REPO_URL),
              })
            }
            .width('100%')
            .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
            .borderRadius(SECTION_CARD_RADIUS)
            .clip(true)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 20, bottom: 24, left: 16, right: 16 })

          // ── 项目信息 ────────────────────────────────────────
          Column({ space: 0 }) {
            PlaybackSectionTitle({ title: $r('app.string.yt_about_project_info') })

            Column({ space: 0 }) {
              OptionItem({
                icon: $r('sys.symbol.doc_plaintext'),
                title: $r('app.string.yt_about_open_source'),
                subtitle: `${OPEN_SOURCE_ITEMS.length} ${getContext().resourceManager.getStringSync($r('app.string.yt_label_projects').id)}`,
                iconColor: this.themePrimary,
                transparentBackground: true,
                onClickAction: () => { this.onNavigate('about_open_source'); }
              })
              Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
              OptionItem({
                icon: $r('sys.symbol.star_fill'),
                title: $r('app.string.yt_about_ai_models'),
                subtitle: `${AI_MODELS.length} ${getContext().resourceManager.getStringSync($r('app.string.yt_label_models').id)}`,
                iconColor: this.themePrimary,
                transparentBackground: true,
                onClickAction: () => { this.onNavigate('about_ai_models'); }
              })
              Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
              OptionItem({
                icon: $r('sys.symbol.clock'),
                title: $r('app.string.yt_about_changelog'),
                subtitle: `${getContext().resourceManager.getStringSync($r('app.string.yt_label_latest_version').id)}${CHANGELOG[0].version}`,
                iconColor: this.themePrimary,
                transparentBackground: true,
                onClickAction: () => { this.onNavigate('about_changelog'); }
              })
            }
            .width('100%')
            .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
            .borderRadius(SECTION_CARD_RADIUS)
            .clip(true)
          }
          .width('100%').padding({ left: 16, right: 16 })

          // ── 底部版权 ──
          Column() {
            Text(`YourPipe v${getAppVersion().versionName}  ·  GPL-3.0`)
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
    .backgroundColor(Color.Transparent)
  }

  build() {
    this.MainContent()
  }
}
