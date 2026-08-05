import { curves } from '@kit.ArkUI';
import { AppLog } from '../../common/AppLog';
import { PreferencesStore } from '../../common/PreferencesStore';

const logger = AppLog.getInstance('HelpGuidePage');

/** Preferences key: 'true' = guide already seen, no auto popup on launch. */
export const PREF_HELP_GUIDE_SEEN: string = 'cfg_help_seen';

export type HelpGuideMode = 'firstLaunch' | 'fromSettings';

export interface HelpGuidePageParams {
  mode: HelpGuideMode;
  onResetSettings: () => void;
  onFinish: () => void;
}

interface GuidePageItem {
  illustration: Resource | null;
  title: ResourceStr;
  desc: ResourceStr;
  details: ResourceStr[];
  isWelcome: boolean;
}

/**
 * 新手引导/帮助页：Swiper 翻页，每页一个主题（插图 + 标题 + 简述）。
 * firstLaunch 模式带"跳过"并作为全屏覆盖层；fromSettings 模式嵌入设置面板。
 * 结束或跳过都会把 cfg_help_seen 置为已读。
 */
@Component
export struct HelpGuidePage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @Consume('safeAreaTop') safeAreaTop: number;
  @Consume('safeAreaBottom') safeAreaBottom: number;
  @Prop params: HelpGuidePageParams = {
    mode: 'fromSettings',
    onResetSettings: () => {},
    onFinish: () => {}
  };
  @State currentIndex: number = 0;
  @State welcomeShown: boolean = false;

  private readonly pages: GuidePageItem[] = [
    {
      illustration: null,
      title: $r('app.string.new_app_name'),
      desc: $r('app.string.yt_guide_p1_desc'),
      details: [],
      isWelcome: true
    },
    {
      illustration: $r('app.media.guide_signin'),
      title: $r('app.string.yt_guide_p2_title'),
      desc: $r('app.string.yt_guide_p2_desc'),
      details: [],
      isWelcome: false
    },
    {
      illustration: $r('app.media.guide_account'),
      title: $r('app.string.yt_guide_p3_title'),
      desc: $r('app.string.yt_guide_p3_desc'),
      details: [
        $r('app.string.yt_guide_p3_user_data'),
        $r('app.string.yt_guide_p3_playback')
      ],
      isWelcome: false
    },
    {
      illustration: $r('app.media.guide_network'),
      title: $r('app.string.yt_guide_p4_title'),
      desc: $r('app.string.yt_guide_p4_desc'),
      details: [],
      isWelcome: false
    },
    {
      illustration: $r('app.media.guide_quality'),
      title: $r('app.string.yt_guide_p5_title'),
      desc: $r('app.string.yt_guide_p5_desc'),
      details: [],
      isWelcome: false
    },
    {
      illustration: $r('app.media.guide_download'),
      title: $r('app.string.yt_guide_p6_title'),
      desc: $r('app.string.yt_guide_p6_desc'),
      details: [],
      isWelcome: false
    }
  ];

  aboutToAppear(): void {
    // 欢迎页入场动画：等初始帧渲染后再触发
    setTimeout(() => {
      this.welcomeShown = true;
    }, 80);
  }

  private isLastPage(): boolean {
    return this.currentIndex >= this.pages.length - 1;
  }

  private finishGuide(): void {
    PreferencesStore.setString(PREF_HELP_GUIDE_SEEN, 'true');
    logger.info(`help guide marked seen, mode=${this.params.mode}`);
    this.params.onFinish();
  }

  private onPrimaryClick(): void {
    if (this.isLastPage()) {
      this.finishGuide();
    } else {
      this.currentIndex += 1;
    }
  }

  @Builder
  private WelcomeContent() {
    Column({ space: 0 }) {
      Image($r('app.media.app_icon'))
        .width(96)
        .height(96)
        .borderRadius(24)
        .scale({ x: this.welcomeShown ? 1 : 0.6, y: this.welcomeShown ? 1 : 0.6 })
        .opacity(this.welcomeShown ? 1 : 0)
        .animation({ duration: 500, curve: curves.springMotion(0.5, 0.7) })

      Text($r('app.string.new_app_name'))
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.yourtube_text_primary'))
        .margin({ top: 24 })
        .opacity(this.welcomeShown ? 1 : 0)
        .translate({ x: 0, y: this.welcomeShown ? 0 : 16 })
        .animation({ duration: 400, delay: 150, curve: Curve.EaseOut })

      Text($r('app.string.yt_guide_p1_desc'))
        .fontSize(15)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .textAlign(TextAlign.Center)
        .lineHeight(24)
        .margin({ top: 16 })
        .opacity(this.welcomeShown ? 1 : 0)
        .translate({ x: 0, y: this.welcomeShown ? 0 : 16 })
        .animation({ duration: 400, delay: 300, curve: Curve.EaseOut })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private StandardContent(item: GuidePageItem) {
    Column({ space: 0 }) {
      if (item.illustration !== null) {
        Image(item.illustration)
          .width('100%')
          .aspectRatio(1.5)
          .objectFit(ImageFit.Contain)
          .borderRadius($r('app.float.common_border_radius_7'))
          .clip(true)
      }

      Text(item.title)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.yourtube_text_primary'))
        .textAlign(TextAlign.Center)
        .margin({ top: item.details.length > 0 ? 20 : 28 })

      Text(item.desc)
        .fontSize(15)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .textAlign(TextAlign.Center)
        .lineHeight(24)
        .margin({ top: 14 })

      if (item.details.length > 0) {
        Column({ space: 10 }) {
          ForEach(item.details, (detail: ResourceStr, index: number) => {
            Row({ space: 10 }) {
              Row()
                .width(4)
                .height(24)
                .borderRadius(2)
                .backgroundColor(this.themePrimary)

              Text(detail)
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_primary'))
                .lineHeight(18)
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .borderRadius($r('app.float.common_border_radius_5'))
            .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          }, (_detail: ResourceStr, index: number) => `guide_detail_${index}`)
        }
        .width('100%')
        .margin({ top: 12 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      // 顶部：跳过（仅首次启动模式）
      Row() {
        Blank()
        if (this.params.mode === 'firstLaunch' && !this.isLastPage()) {
          Text($r('app.string.yt_guide_skip'))
            .fontSize(14)
            .fontColor($r('app.color.yourtube_text_secondary'))
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .onClick(() => {
              this.finishGuide();
            })
        }
      }
      .width('100%')
      .height(44)
      // firstLaunch 覆盖层位于 Navigation 内容区（标题栏之下），需额外避开标题栏高度
      .margin({ top: this.safeAreaTop + (this.params.mode === 'firstLaunch' ? 48 : 8) })

      // 内容：Swiper 翻页
      Swiper() {
        ForEach(this.pages, (item: GuidePageItem, index: number) => {
          Column() {
            if (item.isWelcome) {
              this.WelcomeContent()
            } else {
              Scroll() {
                Column() {
                  this.StandardContent(item)
                }
                .width('100%')
                .padding({ top: 20, bottom: 20 })
              }
              .width('100%')
              .height('100%')
              .scrollBar(BarState.Off)
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(item.isWelcome ? FlexAlign.Center : FlexAlign.Start)
          .padding({ left: 32, right: 32 })
          // 翻页内容动画：非当前页淡出并横向偏移
          .opacity(this.currentIndex === index ? 1 : 0)
          .translate({ x: this.currentIndex === index ? 0 : (index < this.currentIndex ? -24 : 24) })
          .animation({ duration: 300, curve: Curve.EaseOut })
        }, (_item: GuidePageItem, index: number) => index.toString())
      }
      .index($$this.currentIndex)
      .loop(false)
      .indicator(false)
      .duration(300)
      .width('100%')
      .layoutWeight(1)

      // 圆点指示器
      Row({ space: 8 }) {
        ForEach(this.pages, (_dot: GuidePageItem, index: number) => {
          Row()
            .width(this.currentIndex === index ? 20 : 8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(this.currentIndex === index
              ? this.themePrimary
              : $r('app.color.yourtube_divider'))
            .animation({ duration: 200, curve: Curve.EaseOut })
        }, (_dot: GuidePageItem, index: number) => `dot_${index}`)
      }
      .justifyContent(FlexAlign.Center)
      .margin({ bottom: 20 })

      if (this.isLastPage()) {
        Button($r('app.string.yt_option_reset_settings'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themePrimary)
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: this.themePrimary })
          .borderRadius(24)
          .width('72%')
          .height(48)
          .margin({ bottom: 12 })
          .onClick(() => {
            this.params.onResetSettings();
          })
      }

      // 主按钮：下一页 / 完成
      Button(this.isLastPage() ? $r('app.string.yt_guide_done') : $r('app.string.yt_guide_next'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor(this.themePrimary)
        .borderRadius(24)
        .width('72%')
        .height(48)
        .margin({ bottom: this.safeAreaBottom > 0 ? this.safeAreaBottom + 16 : 32 })
        .onClick(() => {
          this.onPrimaryClick();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
