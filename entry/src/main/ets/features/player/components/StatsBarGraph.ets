/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

const MAX_POINTS: number = 60;
const GRAPH_HEIGHT_VP: number = 64;
const PADDING_TOP_VP: number = 6;
const PADDING_BOTTOM_VP: number = 6;
const FALLBACK_SPEED_REFERENCE_BPS: number = 5 * 1000 * 1000;
const COLOR_GOOD: string = '#34A853';
const COLOR_WARN: string = '#F9AB00';
const COLOR_BAD: string = '#E53935';
const COLOR_GRID: string = 'rgba(128, 128, 128, 0.22)';
const COLOR_IDLE_LINE: string = 'rgba(128, 128, 128, 0.35)';

interface ChartPoint {
  x: number;
  y: number;
}

/**
 * 现代平滑折线面积图（Area Spline Chart），基于 Canvas + CanvasRenderingContext2D 绘制：
 * - 右对齐最新采样点，最多保留最近 60 个样本；
 * - 二次贝塞尔平滑曲线 + 柔和竖向线性渐变面积填充 + 辅助水平虚线 + 末端实时高亮圆点；
 * - 颜色随当前最新样本健康度自动在绿/黄/红间切换。
 */
@Component
export struct StatsBarGraph {
  /** Oldest first, latest last. At most the last 60 samples are rendered. */
  @Prop @Watch('onSamplesChanged') samples: number[] = [];
  /** 'speed' | 'buffer' */
  @Prop kind: string = 'speed';
  /** Speed reference (video+audio bitrate, bps). <=0 falls back to 5 Mbps. */
  @Prop referenceBps: number = 0;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasReady: boolean = false;

  private onSamplesChanged(): void {
    this.drawGraph();
  }

  private visibleSamples(): number[] {
    if (this.samples.length <= MAX_POINTS) {
      return this.samples;
    }
    return this.samples.slice(this.samples.length - MAX_POINTS);
  }

  private maxScale(samples: number[]): number {
    let maxSample: number = 0;
    for (let i = 0; i < samples.length; i++) {
      if (samples[i] > maxSample) {
        maxSample = samples[i];
      }
    }
    if (this.kind === 'speed') {
      const reference: number = this.referenceBps > 0 ? this.referenceBps : FALLBACK_SPEED_REFERENCE_BPS;
      return Math.max(maxSample * 1.15, reference * 1.8, 1);
    }
    return Math.max(maxSample * 1.15, 10);
  }

  private accentColor(latestSample: number): string {
    if (latestSample <= 0) {
      return COLOR_IDLE_LINE;
    }
    if (this.kind === 'speed') {
      const reference: number = this.referenceBps > 0 ? this.referenceBps : FALLBACK_SPEED_REFERENCE_BPS;
      const ratio: number = latestSample / reference;
      if (ratio >= 1.2) {
        return COLOR_GOOD;
      }
      if (ratio >= 0.8) {
        return COLOR_WARN;
      }
      return COLOR_BAD;
    }
    if (latestSample >= 8) {
      return COLOR_GOOD;
    }
    if (latestSample >= 3) {
      return COLOR_WARN;
    }
    return COLOR_BAD;
  }

  private hexToRgba(hex: string, alpha: number): string {
    if (!hex.startsWith('#') || hex.length !== 7) {
      return `rgba(128, 128, 128, ${alpha})`;
    }
    const r = parseInt(hex.substring(1, 3), 16);
    const g = parseInt(hex.substring(3, 5), 16);
    const b = parseInt(hex.substring(5, 7), 16);
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
  }

  private drawGraph(): void {
    if (!this.canvasReady) {
      return;
    }
    const ctx = this.context;
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);

    const plotTop: number = PADDING_TOP_VP;
    const plotBottom: number = Math.max(plotTop + 1, h - PADDING_BOTTOM_VP);
    const plotH: number = plotBottom - plotTop;

    // 1. 辅助参考虚线（中线 & 底线）
    ctx.save();
    ctx.strokeStyle = COLOR_GRID;
    ctx.lineWidth = 1;
    ctx.setLineDash([3, 3]);
    const midY = plotTop + plotH * 0.5;
    ctx.beginPath();
    ctx.moveTo(0, midY);
    ctx.lineTo(w, midY);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.beginPath();
    ctx.moveTo(0, plotBottom);
    ctx.lineTo(w, plotBottom);
    ctx.stroke();
    ctx.restore();

    const samples: number[] = this.visibleSamples();
    if (samples.length === 0) {
      return;
    }

    const scale: number = this.maxScale(samples);
    const stepX: number = w / Math.max(MAX_POINTS - 1, 1);
    const points: ChartPoint[] = [];
    for (let i = 0; i < samples.length; i++) {
      const slotIdx = MAX_POINTS - samples.length + i;
      const x = Math.min(w, Math.max(0, slotIdx * stepX));
      const clamped = Math.max(0, Math.min(samples[i], scale));
      const y = plotBottom - (clamped / scale) * plotH;
      points.push({ x, y });
    }

    const latestSample = samples[samples.length - 1];
    const strokeHex = this.accentColor(latestSample);

    // 2. 平滑二次贝塞尔路径
    ctx.save();
    ctx.beginPath();
    ctx.moveTo(points[0].x, points[0].y);
    if (points.length === 1) {
      ctx.lineTo(points[0].x, points[0].y);
    } else {
      for (let i = 1; i < points.length - 1; i++) {
        const midPtX = (points[i].x + points[i + 1].x) * 0.5;
        const midPtY = (points[i].y + points[i + 1].y) * 0.5;
        ctx.quadraticCurveTo(points[i].x, points[i].y, midPtX, midPtY);
      }
      const last = points[points.length - 1];
      ctx.lineTo(last.x, last.y);
    }

    // 先描曲线
    ctx.strokeStyle = strokeHex;
    ctx.lineWidth = 2;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.stroke();

    // 3. 封闭底边并填充柔和竖向渐变面积
    if (points.length >= 2) {
      const lastPt = points[points.length - 1];
      const firstPt = points[0];
      ctx.lineTo(lastPt.x, plotBottom);
      ctx.lineTo(firstPt.x, plotBottom);
      ctx.closePath();
      const grad = ctx.createLinearGradient(0, plotTop, 0, plotBottom);
      grad.addColorStop(0.0, this.hexToRgba(strokeHex, 0.36));
      grad.addColorStop(1.0, this.hexToRgba(strokeHex, 0.02));
      ctx.fillStyle = grad;
      ctx.fill();
    }

    // 4. 末端实时高光圆点
    const tip = points[points.length - 1];
    ctx.beginPath();
    ctx.arc(tip.x, tip.y, 4.5, 0, Math.PI * 2);
    ctx.fillStyle = this.hexToRgba(strokeHex, 0.25);
    ctx.fill();
    ctx.beginPath();
    ctx.arc(tip.x, tip.y, 2.5, 0, Math.PI * 2);
    ctx.fillStyle = strokeHex;
    ctx.fill();
    ctx.restore();
  }

  build() {
    Canvas(this.context)
      .width('100%')
      .height(GRAPH_HEIGHT_VP)
      .borderRadius(8)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .onReady(() => {
        this.canvasReady = true;
        this.drawGraph();
      })
  }
}
