import { ChapterInfo, HeatmapPoint, StoryboardFrame, StoryboardInfo, getStoryboardFrame, secondToTime } from 'mediaservice';
import { SponsorSegment } from '../../../common/experimental/SponsorBlockClient';
import { NetworkProxyStatus } from '../../../common/NetworkProxyConfig';

const HEATMAP_HEIGHT_VP: number = 18;
const JUMP_AHEAD_MIN_LEAD_SEC: number = 5;
const JUMP_AHEAD_MIN_INTENSITY: number = 0.75;

/** SponsorBlock 类别色表（进度条与章节/片段面板共用）。 */
export function getSponsorCategoryColor(category: string): string {
  switch (category) {
    case 'sponsor':
      return '#00D400';
    case 'selfpromo':
      return '#FFFF00';
    case 'interaction':
      return '#CC00FF';
    case 'intro':
      return '#00FFFF';
    case 'outro':
      return '#0202ED';
    case 'preview':
      return '#008FD6';
    case 'music_offtopic':
      return '#FF9900';
    case 'filler':
      return '#7300FF';
    case 'poi_highlight':
      return '#FF1684';
    default:
      return '#00D400';
  }
}

/** 根据时间点查找命中的章节（按 startTimeSeconds 升序）。 */
export function findChapterAtTime(chapters: ChapterInfo[], sec: number): ChapterInfo | null {
  if (!chapters || chapters.length === 0) {
    return null;
  }
  const safeSec = Number.isFinite(sec) && sec > 0 ? sec : 0;
  let matched: ChapterInfo | null = null;
  for (let i = 0; i < chapters.length; i++) {
    const ch = chapters[i];
    if (ch.startTimeSeconds > safeSec) {
      break;
    }
    matched = ch;
  }
  return matched;
}

/**
 * 基于 Most Replayed 热力图查找当前进度前方的下一个显著高能峰值：
 * 首个满足 `startSec > currentTimeSec + 5` 且 `intensity >= 0.75` 的连续高能簇内的最高点。
 */
export function findNextJumpAheadPeak(
  heatmap: HeatmapPoint[],
  currentTimeSec: number,
  durationSec: number
): number | null {
  if (!heatmap || heatmap.length === 0 || !Number.isFinite(currentTimeSec)) {
    return null;
  }
  const minStart = Math.max(0, currentTimeSec) + JUMP_AHEAD_MIN_LEAD_SEC;
  const maxStart = durationSec > 0 ? Math.max(0, durationSec - 2) : Number.MAX_SAFE_INTEGER;
  let clusterStarted = false;
  let bestSec: number = -1;
  let bestIntensity: number = -1;
  for (let i = 0; i < heatmap.length; i++) {
    const point = heatmap[i];
    if (!Number.isFinite(point.startSec) || !Number.isFinite(point.intensity)) {
      continue;
    }
    if (point.startSec <= minStart) {
      continue;
    }
    if (point.startSec >= maxStart) {
      break;
    }
    if (point.intensity >= JUMP_AHEAD_MIN_INTENSITY) {
      clusterStarted = true;
      if (point.intensity > bestIntensity) {
        bestIntensity = point.intensity;
        bestSec = point.startSec;
      }
    } else if (clusterStarted) {
      break;
    }
  }
  return bestSec >= 0 ? bestSec : null;
}

interface SeekPreviewFrameSize {
  displayW: number;
  displayH: number;
}

/**
 * 进度条轨道叠加层（挂载在 PlayControl 进度条 Stack 内部，纯视觉、HitTestMode.None 穿透触摸）：
 * 1. Most Replayed 热力图曲线（轨道上方 18vp，仅点播且有热力图数据时渲染）
 * 2. SponsorBlock 彩色片段条 + poi_highlight 标记点
 * 3. 章节分割刻度线
 */
@Component
export struct SeekBarTrackOverlay {
  @Prop @Watch('onTrackDataChanged') heatmap: HeatmapPoint[] = [];
  @Prop @Watch('onTrackDataChanged') segments: SponsorSegment[] = [];
  @Prop @Watch('onTrackDataChanged') chapters: ChapterInfo[] = [];
  @Prop @Watch('onTrackDataChanged') durationSec: number = 0;
  @Prop @Watch('onTrackDataChanged') trackThicknessVp: number = 4;
  @Prop @Watch('onTrackDataChanged') isLive: boolean = false;

  private heatmapSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private heatmapCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.heatmapSettings);
  private heatmapReady: boolean = false;
  private trackSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private trackCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.trackSettings);
  private trackReady: boolean = false;

  private onTrackDataChanged(): void {
    this.drawHeatmap();
    this.drawTrackMarkers();
  }

  private drawHeatmap(): void {
    if (!this.heatmapReady) {
      return;
    }
    const ctx = this.heatmapCtx;
    const w = ctx.width;
    const h = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    if (this.isLive || this.durationSec <= 0 || !this.heatmap || this.heatmap.length === 0) {
      return;
    }
    const pts = this.heatmap;
    const xs: number[] = [];
    const ys: number[] = [];
    const padTop = 2;
    const drawH = Math.max(2, h - padTop);
    for (let i = 0; i < pts.length; i++) {
      const p = pts[i];
      const centerSec = p.startSec + (p.durationSec > 0 ? p.durationSec / 2 : 0);
      const ratio = Math.max(0, Math.min(1, centerSec / this.durationSec));
      const intensity = Math.max(0, Math.min(1, p.intensity));
      xs.push(ratio * w);
      ys.push(h - intensity * drawH);
    }
    if (xs.length === 0) {
      return;
    }

    ctx.beginPath();
    ctx.moveTo(0, h);
    ctx.lineTo(xs[0], ys[0]);
    for (let i = 0; i < xs.length - 1; i++) {
      const midX = (xs[i] + xs[i + 1]) / 2;
      const midY = (ys[i] + ys[i + 1]) / 2;
      ctx.quadraticCurveTo(xs[i], ys[i], midX, midY);
    }
    const lastIdx = xs.length - 1;
    ctx.lineTo(xs[lastIdx], ys[lastIdx]);
    ctx.lineTo(w, h);
    ctx.closePath();

    const grad = ctx.createLinearGradient(0, 0, 0, h);
    grad.addColorStop(0, 'rgba(255, 255, 255, 0.58)');
    grad.addColorStop(1, 'rgba(255, 255, 255, 0.12)');
    ctx.fillStyle = grad;
    ctx.fill();

    // 顶部柔和暗边 + 清晰高光轮廓线，保证亮/暗视频画面下热力波峰均清晰可辨
    ctx.beginPath();
    ctx.moveTo(xs[0], ys[0]);
    for (let i = 0; i < xs.length - 1; i++) {
      const midX = (xs[i] + xs[i + 1]) / 2;
      const midY = (ys[i] + ys[i + 1]) / 2;
      ctx.quadraticCurveTo(xs[i], ys[i], midX, midY);
    }
    ctx.lineTo(xs[lastIdx], ys[lastIdx]);
    ctx.strokeStyle = 'rgba(0, 0, 0, 0.35)';
    ctx.lineWidth = 2.5;
    ctx.stroke();

    ctx.strokeStyle = 'rgba(255, 255, 255, 0.88)';
    ctx.lineWidth = 1.3;
    ctx.stroke();
  }

  private drawTrackMarkers(): void {
    if (!this.trackReady) {
      return;
    }
    const ctx = this.trackCtx;
    const w = ctx.width;
    const h = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    if (this.isLive || this.durationSec <= 0) {
      return;
    }
    const barH = Math.max(2, Math.min(h, this.trackThicknessVp));
    const barTop = (h - barH) / 2;

    // 1. SponsorBlock 彩色片段（skip 区间条 + poi_highlight 圆点）
    if (this.segments && this.segments.length > 0) {
      for (let i = 0; i < this.segments.length; i++) {
        const seg = this.segments[i];
        const color = getSponsorCategoryColor(seg.category);
        if (seg.actionType === 'poi' || seg.category === 'poi_highlight') {
          const cx = Math.max(3, Math.min(w - 3, (seg.startSec / this.durationSec) * w));
          const cy = h / 2;
          const radius = Math.max(3, Math.min(h / 2 - 0.5, barH * 0.65));
          ctx.beginPath();
          ctx.arc(cx, cy, radius, 0, Math.PI * 2);
          ctx.fillStyle = color;
          ctx.fill();
        } else {
          const start = Math.max(0, Math.min(this.durationSec, seg.startSec));
          const end = Math.max(start, Math.min(this.durationSec, seg.endSec));
          if (end <= start) {
            continue;
          }
          const x = (start / this.durationSec) * w;
          const segW = Math.max(2, ((end - start) / this.durationSec) * w);
          ctx.fillStyle = color;
          ctx.fillRect(x, barTop, segW, barH);
        }
      }
    }

    // 2. 章节分割刻度线
    if (this.chapters && this.chapters.length > 1) {
      ctx.fillStyle = 'rgba(0, 0, 0, 0.78)';
      const tickW = 1.5;
      for (let i = 0; i < this.chapters.length; i++) {
        const sec = this.chapters[i].startTimeSeconds;
        if (sec <= 0.5 || sec >= this.durationSec - 0.5) {
          continue;
        }
        const x = (sec / this.durationSec) * w - tickW / 2;
        ctx.fillRect(x, barTop, tickW, barH);
      }
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 保持 Canvas 常驻挂载：避免切视频时条件卸载/重建导致同一个 CanvasRenderingContext2D 表面失联白屏
      Canvas(this.heatmapCtx)
        .width('100%')
        .height(HEATMAP_HEIGHT_VP)
        .position({ x: 0, y: 0 })
        .hitTestBehavior(HitTestMode.None)
        .onReady(() => {
          this.heatmapReady = true;
          this.drawHeatmap();
        })
        .onAreaChange((_oldArea: Area, _newArea: Area) => {
          if (this.heatmapReady) {
            this.drawHeatmap();
          }
        })

      Canvas(this.trackCtx)
        .width('100%')
        .height(Math.max(10, this.trackThicknessVp + 4))
        .hitTestBehavior(HitTestMode.None)
        .onReady(() => {
          this.trackReady = true;
          this.drawTrackMarkers();
        })
        .onAreaChange((_oldArea: Area, _newArea: Area) => {
          if (this.trackReady) {
            this.drawTrackMarkers();
          }
        })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 拖动进度条 / 横滑 Seek 预览气泡：
 * - 有故事板且加载未失败时，裁剪雪碧图显示对应时间点缩略帧
 * - 显示目标时间与实时命中的章节标题
 * - 拖动进度条时水平跟随并钳制在容器安全边距内；横滑手势时水平居中
 */
@Component
export struct SeekPreviewBubble {
  @StorageProp('networkProxyStatus') private proxyStatus: NetworkProxyStatus = new NetworkProxyStatus();
  @Prop storyboard: StoryboardInfo | undefined = undefined;
  @Prop chapters: ChapterInfo[] = [];
  @Prop @Watch('onPreviewChanged') previewSec: number = 0;
  @Prop durationSec: number = 0;
  @Prop containerWidthVp: number = 0;
  @Prop trackLeftVp: number = 0;
  @Prop trackWidthVp: number = 0;
  @Prop isGestureMode: boolean = false;
  @State failedSheetUrl: string = '';
  @State measuredBubbleW: number = 0;

  private onPreviewChanged(): void {
    const frame = getStoryboardFrame(this.storyboard, this.previewSec);
    if (frame && this.failedSheetUrl.length > 0 && frame.sheetUrl !== this.failedSheetUrl) {
      this.failedSheetUrl = '';
    }
  }

  private currentFrame(): StoryboardFrame | undefined {
    if (this.proxyStatus.enabled && this.proxyStatus.state !== 'ready') {
      return undefined;
    }
    const frame = getStoryboardFrame(this.storyboard, this.previewSec);
    if (!frame || frame.sheetUrl.length === 0 || frame.sheetUrl === this.failedSheetUrl) {
      return undefined;
    }
    return frame;
  }

  private computeFrameSize(frame: StoryboardFrame): SeekPreviewFrameSize {
    const baseW = this.containerWidthVp > 0 && this.containerWidthVp < 420 ? 128 : 160;
    const rawH = Math.round(baseW * (frame.frameHeight / Math.max(1, frame.frameWidth)));
    const clampedH = Math.max(60, Math.min(120, rawH));
    return { displayW: baseW, displayH: clampedH };
  }

  private hasActiveFrame(): boolean {
    return this.currentFrame() !== undefined;
  }

  private activeSheetUrl(): string {
    const frame = this.currentFrame();
    return frame ? frame.sheetUrl : '';
  }

  private activeDisplayW(): number {
    const frame = this.currentFrame();
    return frame ? this.computeFrameSize(frame).displayW : 144;
  }

  private activeDisplayH(): number {
    const frame = this.currentFrame();
    return frame ? this.computeFrameSize(frame).displayH : 81;
  }

  private activeSheetWidth(): number {
    const frame = this.currentFrame();
    return frame ? this.computeFrameSize(frame).displayW * frame.cols : 0;
  }

  private activeSheetHeight(): number {
    const frame = this.currentFrame();
    return frame ? this.computeFrameSize(frame).displayH * frame.rows : 0;
  }

  private activeOffsetX(): number {
    const frame = this.currentFrame();
    return frame ? -frame.col * this.computeFrameSize(frame).displayW : 0;
  }

  private activeOffsetY(): number {
    const frame = this.currentFrame();
    return frame ? -frame.row * this.computeFrameSize(frame).displayH : 0;
  }

  private computeBubbleWidth(): number {
    if (this.measuredBubbleW > 0) {
      return this.measuredBubbleW;
    }
    const frame = this.currentFrame();
    if (frame) {
      return this.computeFrameSize(frame).displayW + 12;
    }
    return 156;
  }

  private computeMaxChapterWidth(): number {
    return this.hasActiveFrame() ? this.activeDisplayW() : 144;
  }

  private computeLeftOffsetVp(): number {
    if (this.isGestureMode) {
      return 0;
    }
    const bubbleW = this.computeBubbleWidth();
    const cw = this.containerWidthVp;
    const margin = 12;
    if (cw <= 0 || this.durationSec <= 0) {
      return Math.max(margin, (cw - bubbleW) / 2);
    }
    const ratio = Math.max(0, Math.min(1, this.previewSec / this.durationSec));
    const thumbCenterX = this.trackWidthVp > 0
      ? (this.trackLeftVp + ratio * this.trackWidthVp)
      : (margin + ratio * Math.max(0, cw - margin * 2));
    const rawLeft = thumbCenterX - bubbleW / 2;
    return Math.max(margin, Math.min(Math.max(margin, cw - bubbleW - margin), rawLeft));
  }

  private currentChapterTitle(): string {
    const ch = findChapterAtTime(this.chapters, this.previewSec);
    return ch ? ch.title : '';
  }

  private formattedTimeLabel(): string {
    const target = secondToTime(Math.floor(Math.max(0, this.previewSec)));
    if (!this.hasActiveFrame() && this.durationSec > 0) {
      return `${target} / ${secondToTime(Math.floor(this.durationSec))}`;
    }
    return target;
  }

  build() {
    Row() {
      Column({ space: 4 }) {
        if (this.hasActiveFrame()) {
          Stack({ alignContent: Alignment.TopStart }) {
            Image(this.activeSheetUrl())
              .width(this.activeSheetWidth())
              .height(this.activeSheetHeight())
              .objectFit(ImageFit.Fill)
              .position({
                x: this.activeOffsetX(),
                y: this.activeOffsetY()
              })
              .hitTestBehavior(HitTestMode.None)
              .onError(() => {
                this.failedSheetUrl = this.activeSheetUrl();
              })
          }
          .width(this.activeDisplayW())
          .height(this.activeDisplayH())
          .borderRadius(6)
          .clip(true)
          .backgroundColor('#FF1A1A1A')
          .hitTestBehavior(HitTestMode.None)
        }

        Text(this.formattedTimeLabel())
          .fontColor(Color.White)
          .fontSize(this.hasActiveFrame() ? 13 : 16)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .hitTestBehavior(HitTestMode.None)

        if (this.currentChapterTitle().length > 0) {
          Text(this.currentChapterTitle())
            .fontColor('#DDFFFFFF')
            .fontSize(11)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .constraintSize({ maxWidth: this.computeMaxChapterWidth() })
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .padding({ left: 6, right: 6, top: 6, bottom: 6 })
      .backgroundColor('#D9000000')
      .borderRadius(10)
      .border({ width: 0.5, color: '#33FFFFFF' })
      .alignItems(HorizontalAlign.Center)
      .constraintSize({ minWidth: 96 })
      .margin({
        left: this.isGestureMode ? 0 : this.computeLeftOffsetVp()
      })
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const w = Number(newArea.width);
        if (Number.isFinite(w) && w > 0 && Math.abs(w - this.measuredBubbleW) >= 0.5) {
          this.measuredBubbleW = w;
        }
      })
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .justifyContent(this.isGestureMode ? FlexAlign.Center : FlexAlign.Start)
    .hitTestBehavior(HitTestMode.None)
  }
}
