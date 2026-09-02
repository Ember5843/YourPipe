/**
 * ASR 字幕共享工具（P3）：cue 模型 + 轨 key + WebVTT 构建。
 * 实时路径（AsrLiveCaptionService）使用，VTT 格式逻辑只维护这一份。
 */
export interface AsrCue {
  s: number;
  e: number;
  t: string;
}

/** 应用侧生成的 ASR 字幕轨 key（占用 currentSubtitleUrl 走 overlay 管线）。 */
export function asrTrackKey(videoId: string): string {
  return `asr://${videoId}`;
}

export function buildAsrVtt(cues: AsrCue[]): string {
  const parts: string[] = ['WEBVTT'];
  for (const cue of cues) {
    parts.push(`${formatAsrTs(cue.s)} --> ${formatAsrTs(cue.e)}\n${cue.t}`);
  }
  return parts.join('\n\n') + '\n';
}

function formatAsrTs(ms: number): string {
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  const s = Math.floor((ms % 60000) / 1000);
  const milli = ms % 1000;
  return `${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}.${milli.toString().padStart(3, '0')}`;
}
