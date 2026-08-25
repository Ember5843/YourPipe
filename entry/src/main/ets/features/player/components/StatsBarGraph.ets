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

const MAX_BARS: number = 60;
const GRAPH_HEIGHT_VP: number = 56;
const BAR_PLACEHOLDER_HEIGHT_PX: number = 2;
const BAR_GAP_PX: number = 1;
const FALLBACK_SPEED_REFERENCE_BPS: number = 5 * 1000 * 1000;
const COLOR_GOOD: string = '#34A853';
const COLOR_WARN: string = '#F9AB00';
const COLOR_BAD: string = '#E53935';
// Matches app.color.yourtube_divider (#E0E0E0); Canvas fillStyle needs a literal.
const COLOR_PLACEHOLDER: string = '#E0E0E0';

/**
 * Stats-for-Nerds style live bar graph, drawn with Canvas +
 * CanvasRenderingContext2D (the official data-visualization pattern).
 * Bars are bottom-aligned, right-aligned to the latest sample; older samples
 * sit to the left and the left side stays empty until 60 samples accumulate.
 * kind 'speed': samples in bytes/sec, colored against referenceBps (stream bitrate);
 * kind 'buffer': samples in seconds, colored by absolute buffered duration.
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
    if (this.samples.length <= MAX_BARS) {
      return this.samples;
    }
    return this.samples.slice(this.samples.length - MAX_BARS);
  }

  private maxScale(): number {
    let maxSample: number = 0;
    this.samples.forEach((value: number) => {
      if (value > maxSample) {
        maxSample = value;
      }
    });
    if (this.kind === 'speed') {
      const reference: number = this.referenceBps > 0 ? this.referenceBps : FALLBACK_SPEED_REFERENCE_BPS;
      return Math.max(maxSample, reference * 2, 1);
    }
    return Math.max(maxSample, 10);
  }

  private barColor(sample: number): string {
    if (sample <= 0) {
      return COLOR_PLACEHOLDER;
    }
    if (this.kind === 'speed') {
      const reference: number = this.referenceBps > 0 ? this.referenceBps : FALLBACK_SPEED_REFERENCE_BPS;
      const ratio: number = sample / reference;
      if (ratio >= 1.2) {
        return COLOR_GOOD;
      }
      if (ratio >= 0.8) {
        return COLOR_WARN;
      }
      return COLOR_BAD;
    }
    if (sample >= 8) {
      return COLOR_GOOD;
    }
    if (sample >= 3) {
      return COLOR_WARN;
    }
    return COLOR_BAD;
  }

  private drawGraph(): void {
    if (!this.canvasReady) {
      return;
    }
    const w: number = this.context.width;
    const h: number = this.context.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    this.context.clearRect(0, 0, w, h);

    const samples: number[] = this.visibleSamples();
    const scale: number = this.maxScale();
    const slotW: number = w / MAX_BARS;
    const barW: number = Math.max(slotW - BAR_GAP_PX, 1);
    const drawableH: number = Math.max(h - BAR_PLACEHOLDER_HEIGHT_PX, 0);

    for (let i = 0; i < MAX_BARS; i++) {
      // Right-aligned: latest sample at the right edge, left slots stay
      // empty until enough samples have accumulated. An empty graph still
      // renders the full placeholder baseline.
      const sampleIndex: number = samples.length - MAX_BARS + i;
      const sample: number = sampleIndex >= 0 ? samples[sampleIndex] : 0;
      const x: number = w - (MAX_BARS - i) * slotW;
      let barH: number;
      if (sample <= 0) {
        barH = BAR_PLACEHOLDER_HEIGHT_PX;
      } else {
        barH = Math.min(1, sample / scale) * drawableH;
      }
      const y: number = h - barH;
      this.context.fillStyle = this.barColor(sample);
      this.context.fillRect(x, y, barW, barH);
    }
  }

  build() {
    Canvas(this.context)
      .width('100%')
      .height(GRAPH_HEIGHT_VP)
      .onReady(() => {
        this.canvasReady = true;
        this.drawGraph();
      })
      .onAreaChange(() => {
        this.drawGraph();
      })
  }
}
