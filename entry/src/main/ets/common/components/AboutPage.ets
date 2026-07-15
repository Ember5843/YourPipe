import { UIConfig } from '../AppState';
import { customAnimationUtil } from '../AnimationUtil';
import { OptionItem } from './OptionItem';
import { pasteboard } from '@kit.BasicServicesKit';
import { HdsNavigation, HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { buildYourTubeTitleBar } from './HdsTitleBar';

const APP_VERSION = '0.5.3';
const APP_BUILD = '1000012';

// ─── 数据 ──────────────────────────────────────────────────────────────────────

interface OpenSourceItem {
  name: string;
  desc: string;
  license: string;
}

interface ChangelogEntry {
  version: string;
  date: string;
  changes: string[];
}

const OPEN_SOURCE_ITEMS: OpenSourceItem[] = [
  { name: 'NewPipe', desc: '开源 Android YouTube 客户端，提供视频浏览、搜索与流媒体解析参考', license: 'GPL-3.0' },
  { name: 'iPlay', desc: '跨平台媒体播放器，支持 Emby、Jellyfin 多站点切换与自定义播放', license: 'MIT' },
  { name: 'yt-dlp', desc: '功能丰富的命令行音视频下载器，支持数千个站点与多种格式', license: 'Unlicense' },
  { name: 'FinVideo', desc: 'HarmonyOS NEXT 上的 Jellyfin / Emby / Plex 视频播放器', license: 'GPL-3.0' },
  { name: '华为开发者案例', desc: '长视频播放控制、AVPlayer 构建等 HarmonyOS 官方开发参考', license: '参考' },
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
    version: '0.5.3', date: '2026-07-14',
    changes: [
      '新增 YouTube SABR/UMP 流媒体播放支持，提升新格式视频、高画质视频及受限播放场景的兼容性',
      '重构视频解析与客户端选择流程，对齐 PipePipe 请求行为并恢复远程签名解密服务，减少重复提取和启动等待',
      '完善本地 DASH 媒体代理，支持音视频分轨、分段缓存、精确拖动、断流恢复与播放结束处理',
      '加入 SABR PoToken 支持，优化签名参数、请求头与二进制响应处理，减少 403、无法播放和加载失败',
      '优化播放器状态同步、清晰度与音轨切换，修复画面已播放仍持续转圈、拖动错位及音轨菜单异常',
      '升级播放列表解析与翻页机制，兼容新版列表结构、锁定内容和 continuation，改善列表加载与连续播放',
      '整理账号与数据管理入口，改进登录状态、观看记录、本地页面、下载选项及播放偏好之间的联动',
      '优化首页推荐、视频卡片、主题色、画中画和系统媒体会话体验，并修复多处界面与播放稳定性问题',
    ],
  },
  {
    version: '0.5.2', date: '2026-07-13',
    changes: [
      '播放页新增「仅音频」：关视频听声音，封面替代画面，进度与播控仍可用',
      '仅音频时不进画中画；回前台保持仅音频，需手动恢复视频',
      '后台可延迟关闭视频以省电（播放设置可调）',
      '修复系统播报打断：正确 duck 降音且避免二次压音导致静音',
      '横竖屏、全屏与窗口播放更顺滑，减少闪黑与画面模糊',
      '登录后主页更贴合账号状态，可同步云端观看记录与订阅',
      '视频卡片、直播角标与页面安全区显示更清晰',
      '支持应用流转与碰一碰分享视频链接',
    ],
  },
  {
    version: '0.5.1', date: '2026-06-23',
    changes: [
      '修复部分已知bug',
      '对齐PipePipe问题',
      '修复登录后无法观看的bug',
      '修复横屏模式信息栏不当弹出的问题',
      '优化设置页面UI',
      '完成本地解密逻辑验证，准备实装',
    ],
  },
  {
    version: '0.5.0', date: '2026-06-18',
    changes: [
      '更换系统播放引擎与第三方FFMpeg至MPVPlayer',
      '恢复高分辨率播放和字幕功能',
      '支持HEVC/H.264硬件解码；API 23+ 尝试 VP9/AV1 硬件解码',
      '加入真HDR显示',
      '优化非登录状态下网络传输库能力',
      '优化错误显示',
      '优化UI和设置选项',
      '应用PipePipe最新版本补丁',
    ],
  },
  {
    version: '0.4.1', date: '2026-05-30',
    changes: [
      '优化视频加载速度',
      '应用pipepipe5.1.1版本补丁',
      '允许谷歌登录，基本消除bot protection问题',
      '优化多种设备的全屏交互机制',
      '开发播放页面多个模块',
      '初步做完下载功能',
      '完全播放列表功能',
      '接入系统及投屏入口，实验性初步接入应用流转'
    ],
  },
  {
    version: '0.4.0', date: '2026-05-25',
    changes: [
      '基本完成yt-dlp生态分析与接入接口',
      '允许谷歌登录，基本消除bot protection问题',
      '优化播放机制',
      '使用云端解码替代本地解码，更加稳定',
    ],
  },
  {
    version: '0.3.1', date: '2026-05-22',
    changes: [
      '完善页面栈与小窗播放',
      '加入服务器缓存，播放更流畅',
      '优化ui与交互方式',
      '更多页面与尺寸适配',
      '继续精简先前代码防bug',
      '初步开发谷歌登录，验证pipepipe登录流程可行性',
      '优化后台播放稳定性',
    ],
  },
  {
    version: '0.3.0', date: '2026-05-18',
    changes: [
      '最终实验选定中转http服务器方案',
      '回退到系统级播放器完善生命周期',
      '优化ui与交互方式',
      '更多页面与尺寸适配',
      '删除大量先前的库与头文件，精简防bug',
      '初步开发谷歌登录，验证smarttube可行性',
      '优化后台播放稳定性',
    ],
  },
  {
    version: '0.2.0', date: '2026-05-01',
    changes: [
      '重构项目代码，优化整体生命周期管理与开发速度，全新启程',
      '优化播放与直播部分，直播更流畅，发热更少',
      '更多选项，可自定义的播放选项',
      '更丰富的报错信息与日志管理',
      '增加多国语言优化适配',
      '更新 NewPipe 核心代码，优化网络连接和解码，功能更稳定',
      '优化后台播放稳定性',
      '系统级 AVPlayer 播放，稳定性与功耗优化',
    ],
  },
  {
    version: '0.1.2', date: '2026-04-27',
    changes: [
      '修复应用 UI 语言切换导致的界面卡死问题',
      '优化内容语言列表中文变体（简体 / 繁体香港 / 繁体台湾）显示',
      '日志下载完成后显示保存路径提示',
      '新增关于页面',
      '修复高级分辨率禁用选项不生效的问题',
      '统一设置页各模块视觉风格',
    ],
  },
  {
    version: '0.1.1', date: '2026-04-25',
    changes: [
      '接入 MPV 播放内核，支持硬件解码与高分辨率视频',
      '实现后台播放与系统播控中心集成',
      '完成语言与地区设置，支持内容语言 / 地区切换',
      '添加运行日志系统，支持会话导出',
      '优化平板横屏播放器布局',
    ],
  },
  {
    version: '0.1.0', date: '2026-04-23',
    changes: [
      '首次发布：基础 YouTube 视频浏览与搜索',
      '接入 NewPipe Extractor 提取引擎',
      '支持订阅频道、收藏夹与播放列表管理',
      '支持直播流播放',
      '评论列表与频道页面',
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

              ForEach(item.changes, (change: string) => {
                Row({ space: 8 }) {
                  Text('·').fontSize(16).fontColor(this.themePrimary).width(12)
                  Text(change)
                    .fontSize(13).fontColor($r('app.color.yourtube_text_secondary'))
                    .layoutWeight(1).lineHeight(20)
                }
                .width('100%').alignItems(VerticalAlign.Top).padding({ bottom: 5 })
              }, (c: string) => c)
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
      this.getUIContext().getPromptAction().showToast({ message: '已复制', duration: 2000 });
      console.info('Copy succeeded: ' + text);
    }).catch((error: Error) => {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败', duration: 2000 });
      console.error(`Copy error: ${error.message}`);
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
              Text(`版本 ${APP_VERSION}`)
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
                  Text('应用包名')
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
              subtitle: `${OPEN_SOURCE_ITEMS.length} 个项目`,
              iconColor: $r('app.color.yourtube_option_icon_language'),
              onClickAction: () => { this.aboutNavStack.pushPathByName('open_source', null); }
            })

            OptionItem({
              icon: $r('sys.symbol.star_fill'),
              title: $r('app.string.yt_about_ai_models'),
              subtitle: `${AI_MODELS.length} 个模型`,
              iconColor: '#8B5CF6',
              onClickAction: () => { this.aboutNavStack.pushPathByName('ai_models', null); }
            })

            OptionItem({
              icon: $r('sys.symbol.clock'),
              title: $r('app.string.yt_about_changelog'),
              subtitle: `最新 v${CHANGELOG[0].version}`,
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
