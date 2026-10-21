import { ActionHub } from '../../../common/ActionHub';
import { AppLog } from '../../../common/AppLog';
import { UIConfig } from '../../../common/AppState';

const logger = AppLog.getInstance('ShortsBall');
const TAG = '[Shorts]';

const BALL_SIZE: number = 48;
const EDGE_MARGIN: number = 8;
/** 默认位置：左下，距左边 16vp；距底部按 tab 栏 + 安全区上移。 */
const DEFAULT_LEFT: number = 16;
const TAB_BAR_CLEARANCE: number = 96;
/** 拖拽结束后这段时间内的抬手不算「点击」（避免拖完顺手进 Shorts）。 */
const DRAG_CLICK_GUARD_MS: number = 400;

/**
 * 主页 Shorts 悬浮球：可自由拖动、松手不吸边、位置按归一化坐标持久化。
 * 只在主页 tab 显示（由 Index 的 if 条件控制），不是系统级悬浮窗。
 *
 * 组件根节点只有 48×48（不做全屏包装层）：全屏透明层即使设
 * HitTestMode.Transparent 也会让下层首页列表收不到点击，实测会导致
 * “首页点不了”。容器尺寸由 Index 根 Stack 的 onAreaChange 传入。
 */
@Component
export struct FloatingShortsBall {
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();

  @Prop @Watch('onContainerChanged') containerWidth: number = 0;
  @Prop @Watch('onContainerChanged') containerHeight: number = 0;

  @State ballX: number = DEFAULT_LEFT;
  @State ballY: number = 400;
  @State dragging: boolean = false;

  private areaWidth: number = 0;
  private areaHeight: number = 0;
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  /** 最近一次拖拽结束的时间戳：窗口内的抬手不算点击。 */
  private lastDragEndMs: number = 0;

  aboutToAppear(): void {
    logger.info(`${TAG} ball_show x=${this.uiConfig.shortsBallX} y=${this.uiConfig.shortsBallY}`);
    this.areaWidth = this.containerWidth;
    this.areaHeight = this.containerHeight;
    this.applyLayout(this.containerWidth, this.containerHeight);
  }

  onContainerChanged(): void {
    if (this.dragging) {
      return;
    }
    this.applyLayout(this.containerWidth, this.containerHeight);
  }

  private clamp(value: number, min: number, max: number): number {
    if (max < min) {
      return min;
    }
    return Math.min(Math.max(value, min), max);
  }

  private applyLayout(width: number, height: number): void {
    if (width <= 0 || height <= 0) {
      return;
    }
    this.areaWidth = width;
    this.areaHeight = height;
    const defaultY = height - BALL_SIZE - this.safeAreaBottom - TAB_BAR_CLEARANCE;
    const storedX = this.uiConfig.shortsBallX;
    const storedY = this.uiConfig.shortsBallY;
    const rawX = storedX >= 0 && storedX <= 1 ? storedX * width : DEFAULT_LEFT;
    const rawY = storedY >= 0 && storedY <= 1 ? storedY * height : defaultY;
    this.ballX = this.clamp(rawX, EDGE_MARGIN, width - BALL_SIZE - EDGE_MARGIN);
    this.ballY = this.clamp(rawY, EDGE_MARGIN, height - BALL_SIZE - EDGE_MARGIN);
  }

  private persistPosition(): void {
    if (this.areaWidth <= 0 || this.areaHeight <= 0) {
      return;
    }
    this.uiConfig.shortsBallX = this.ballX / this.areaWidth;
    this.uiConfig.shortsBallY = this.ballY / this.areaHeight;
    UIConfig.saveToPreferences(this.uiConfig);
    logger.info(`${TAG} ball_move x=${this.ballX.toFixed(0)} y=${this.ballY.toFixed(0)} `
      + `nx=${this.uiConfig.shortsBallX.toFixed(3)} ny=${this.uiConfig.shortsBallY.toFixed(3)}`);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Image($r('app.media.ic_shorts_ball'))
        .width(24)
        .height(24)
        .draggable(false)
    }
    .width(BALL_SIZE)
    .height(BALL_SIZE)
    .borderRadius(BALL_SIZE / 2)
    .backgroundColor('#CC000000')
    .shadow({ radius: 8, color: '#40000000', offsetY: 2 })
    .position({ x: this.ballX, y: this.ballY })
    .scale({ x: this.dragging ? 1.06 : 1.0, y: this.dragging ? 1.06 : 1.0 })
    .accessibilityText($r('app.string.yt_shorts_open'))
    .onClick(() => {
      // 拖拽刚结束的抬手不应触发进入 Shorts（用时间窗而不是累计位移：
      // 位移量在拖拽结束后会一直留着，导致**下一次**独立点击也被吞掉）。
      if (Date.now() - this.lastDragEndMs < DRAG_CLICK_GUARD_MS) {
        logger.info(`${TAG} ball_click_ignored in_drag_guard`);
        return;
      }
      logger.info(`${TAG} ball_click`);
      this.actionHub.openShorts();
    })
    .gesture(
      PanGesture({ fingers: 1, distance: 3 })
        .onActionStart(() => {
          this.dragging = true;
          this.dragStartX = this.ballX;
          this.dragStartY = this.ballY;
        })
        .onActionUpdate((event: GestureEvent) => {
          this.ballX = this.clamp(this.dragStartX + event.offsetX,
            EDGE_MARGIN, this.areaWidth - BALL_SIZE - EDGE_MARGIN);
          this.ballY = this.clamp(this.dragStartY + event.offsetY,
            EDGE_MARGIN, this.areaHeight - BALL_SIZE - EDGE_MARGIN);
        })
        .onActionEnd(() => {
          this.dragging = false;
          this.lastDragEndMs = Date.now();
          this.persistPosition();
        })
        .onActionCancel(() => {
          this.dragging = false;
          this.lastDragEndMs = Date.now();
        })
    )
  }
}
