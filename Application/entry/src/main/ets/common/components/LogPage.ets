import { AppLog } from '../AppLog';
/**
 * LogPage.ets - YourPipe 日志查看页面（会话模式）
 *
 * 列表：每个条目 = 一次 LogSession，显示序号、时间、状态、日志条数
 * 操作：单条目右侧「下载」「删除」按钮；顶部「删除全部」按钮
 * 响应式：SessionCard 通过 @ObjectLink 订阅 @Observed LogSession，
 *         logs 数组替换后 logCount 实时刷新，无需重绘整个列表
 */
import common from '@ohos.app.ability.common';
import { picker } from '@kit.CoreFileKit';
import { fileUri as fileUriKit } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { UIConfig } from '../AppState';
import { AppLogStore, LogData, LogSession } from '../AppLogStore';
import { customAnimationUtil } from '../AnimationUtil';

const logger = AppLog.getInstance('LogPage');

// ─── 时间格式化 ──────────────────────────────────────────────────────────────

function formatTimestamp(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number, w: number = 2): string => String(n).padStart(w, '0');
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function formatLogTime(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number, w: number = 2): string => String(n).padStart(w, '0');
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`;
}

// ─── Session 卡片 ─────────────────────────────────────────────────────────────
/**
 * 独立 @Component，通过 @ObjectLink 订阅 LogSession。
 * 当 session.logs 被替换时（AppLogStore.push 内），@Track logs 触发此组件刷新，
 * session.logCount 随之更新，实现条数实时同步。
 */
@Component
struct SessionCard {
  /** 细粒度绑定到 @Observed LogSession */
  @ObjectLink session: LogSession;
  /** 在列表中的显示序号（由外部按倒序传入，最新 Session 序号最大） */
  displayIndex: number = 1;

  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();

  onDeleteSession: (id: string) => void = (_id: string) => {};
  onDownloadSession: (id: string) => void = (_id: string) => {};

  build() {
    Row({ space: 0 }) {
      // ── 左侧：会话信息 ──
      Column({ space: 4 }) {
        // 首行：序号 + 时间 + 状态标签
        Row({ space: 8 }) {
          Text(`#${this.displayIndex}`)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.yourtube_theme_primary'))
            .fontFamily('monospace')

          Text(formatTimestamp(this.session.startTime))
            .fontSize(13)
            .fontColor($r('app.color.yourtube_text_primary'))

          // 状态 badge：直接读 @Track endTime，不用 getter
          if (this.session.endTime === null) {
            Row({ space: 4 }) {
              Circle()
                .width(6)
                .height(6)
                .fill('#FF4444')
              Text($r('app.string.yt_log_session_active'))
                .fontSize(11)
                .fontColor('#FF4444')
            }
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor('#1FFF4444')
          } else {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.checkmark_circle'))
                .fontSize(11)
                .fontColor([$r('app.color.yourtube_text_hint')])
              Text($r('app.string.yt_log_session_saved'))
                .fontSize(11)
                .fontColor($r('app.color.yourtube_text_hint'))
            }
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          }
        }
        .width('100%')

        // 次行：日志条数（直接读 @Track logs.length，不用 getter）
        Text(`${this.session.logs.length} 条日志`)
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_quaternary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding({ right: 12 })

      // ── 右侧：操作按钮 ──
      Row({ space: 4 }) {
        // 下载按钮
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.arrowshape_down_to_line_fill'))
            .fontSize(16)
            .fontColor([$r('app.color.yourtube_text_hint')])
        }
        .width(32)
        .height(32)
        .backgroundColor(Color.Transparent)
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.onDownloadSession(this.session.id);
        })

        // 删除按钮
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(16)
            .fontColor(['#FF4444'])
        }
        .width(32)
        .height(32)
        .backgroundColor(Color.Transparent)
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.onDeleteSession(this.session.id);
        })
      }
    }
    .width('100%')
    .borderRadius(12)
    .padding({ left: 16, right: 8, top: 14, bottom: 14 })
    .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
  }
}

// ─── 主页面 ───────────────────────────────────────────────────────────────────

@Component
export struct LogPage {
  /** 从 Index.ets 的 optionsNavStack 传入，用于返回 */
  onBack?: () => void;

  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  /**
   * 绑定 Session 列表。
   * AppLogStore.push / startListening / stopListening 均会替换此数组引用，
   * 从而触发 @StorageLink 刷新，ForEach 感知列表增减。
   * 单个 Session 的内部变化（条数）由 SessionCard 的 @ObjectLink 单独处理。
   */
  @StorageLink('appLogSessions') sessions: LogSession[] = [];

  @State isExporting: boolean = false;
  /** 正在导出的 Session id（防重复点击） */
  @State exportingId: string = '';

  private readonly THEME_COLOR: ResourceColor = $r('app.color.yourtube_theme_primary');

  // ── 导出单个 Session ──────────────────────────────────────────────────────
  private async exportSession(sessionId: string): Promise<void> {
    if (this.isExporting) {
      return;
    }
    this.isExporting = true;
    this.exportingId = sessionId;
    try {
      const uiContext: UIContext = this.getUIContext();
      const ctx = uiContext.getHostContext() as common.UIAbilityContext;

      const filePicker = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSaveOptions();
      const session = this.sessions.find(s => s.id === sessionId);
      const dateStr = session
        ? new Date(session.startTime).toISOString().replace(/[:.]/g, '-').slice(0, 19)
        : new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
      const fileName = `yourpipe_log_${dateStr}.txt`;
      options.newFileNames = [fileName];
      options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;

      const result = await filePicker.save(options);
      if (!result || result.length === 0) {
        return;
      }

      const snapshot = AppLogStore.getSessionSnapshot(sessionId);
      const lines = snapshot.map((item: LogData) =>
        `[${formatLogTime(item.time)}] [${item.level}] ${item.tag}  ${item.message}`
      );
      const content = lines.join('\n');

      const path = new fileUriKit.FileUri(result[0] + '/' + fileName).path;
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      fs.writeSync(file.fd, content);
      fs.fsync(file.fd);
      fs.closeSync(file);
      // 下载完成后提示保存路径
      try {
        const uiCtx2: UIContext = this.getUIContext();
        uiCtx2.getPromptAction().showToast({
          message: $r('app.string.yt_log_saved_to_downloads'),
          duration: 2000,
        });
      } catch (_te) {}
    } catch (e) {
      logger.error(`exportSession failed: ${JSON.stringify(e)}`);
    } finally {
      this.isExporting = false;
      this.exportingId = '';
    }
  }

  // ── 开关持久化 ───────────────────────────────────────────────────────────
  private toggleLogger(): void {
    const next = new UIConfig();
    next.darkMode = this.uiConfig.darkMode;
    next.userLanguage = this.uiConfig.userLanguage;
    next.systemLanguage = this.uiConfig.systemLanguage;
    next.searchLanguage = this.uiConfig.searchLanguage;
    next.searchCountry = this.uiConfig.searchCountry;
    next.colorPreset = this.uiConfig.colorPreset;
    next.isVibrate = this.uiConfig.isVibrate;
    next.isAnimation = this.uiConfig.isAnimation;
    next.animationSpeed = this.uiConfig.animationSpeed;
    next.enableLogger = !this.uiConfig.enableLogger;
    this.uiConfig = next;
    UIConfig.saveToPreferences(next);

    if (next.enableLogger) {
      AppLogStore.startListening();
    } else {
      AppLogStore.stopListening();
    }
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  build() {
    Column() {
      Column() {
        Text($r('app.string.yt_log_title'))
          .fontSize(13)
          .fontColor($r('app.color.yourtube_text_hint'))
          .fontWeight(FontWeight.Medium)
          .margin({ left: 8, top: 16, bottom: 6 })
          .width('100%')

        // ── 开启日志开关行 ──
        Row() {
          Column() {
            Text($r('app.string.yt_log_enable'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.yourtube_text_primary'))
            Text($r('app.string.yt_log_enable_subtitle'))
              .fontSize(13)
              .fontColor($r('app.color.yourtube_text_quaternary'))
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.uiConfig.enableLogger })
            .selectedColor(this.THEME_COLOR)
            .onChange(() => {
              this.toggleLogger();
            })
        }
        .width('100%')
        .borderRadius(16)
        .constraintSize({ minHeight: 56 })
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.toggleLogger();
        })

        if (this.sessions.length > 0) {
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(18)
              .fontColor(['#FF4444'])
              .width(28)
            Text($r('app.string.yt_log_delete_all_confirm'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FF4444')
              .layoutWeight(1)
          }
          .width('100%')
          .borderRadius(16)
          .constraintSize({ minHeight: 52 })
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .margin({ top: 12 })
          .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
          .onClick(() => {
            AlertDialog.show({
              title: $r('app.string.yt_log_delete_all_confirm'),
              message: '',
              primaryButton: {
                value: $r('app.string.yt_log_delete_confirm_yes'),
                fontColor: '#FF4444',
                action: () => {
                  AppLogStore.clear();
                }
              },
              secondaryButton: {
                value: $r('app.string.yt_log_delete_confirm_no'),
                action: () => {}
              }
            });
          })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })

      // ── Session 列表 ──
      if (!this.uiConfig.enableLogger && this.sessions.length === 0) {
        // 未开启 且 无历史记录
        Column() {
          SymbolGlyph($r('sys.symbol.doc_text'))
            .fontSize(48)
            .fontColor([$r('app.color.yourtube_text_hint')])
            .margin({ bottom: 12 })
          Text($r('app.string.yt_log_disabled_hint'))
            .fontSize(15)
            .fontColor($r('app.color.yourtube_text_hint'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ bottom: 60 })
      } else if (this.sessions.length === 0) {
        // 开启中但尚无记录
        Column() {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(48)
            .fontColor([$r('app.color.yourtube_text_hint')])
            .margin({ bottom: 12 })
          Text($r('app.string.yt_log_no_sessions'))
            .fontSize(15)
            .fontColor($r('app.color.yourtube_text_hint'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ bottom: 60 })
      } else {
        // Session 卡片列表
        List({ space: 8 }) {
          ForEach(this.sessions, (item: LogSession, index: number) => {
            ListItem() {
              // SessionCard 通过 @ObjectLink 绑定 item（@Observed LogSession）
              // logs 被替换时，此卡片自动刷新 logCount，无需重建整个列表
              SessionCard({
                session: item,
                displayIndex: this.sessions.length - index,
                onDeleteSession: (id: string) => {
                  AppLogStore.deleteSession(id);
                },
                onDownloadSession: (id: string) => {
                  this.exportSession(id);
                }
              })
            }
            .transition(customAnimationUtil.isScaleTran(index < 30 ? index : 30, this.uiConfig))
          }, (item: LogSession) => item.id)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, bottom: 16 })
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
