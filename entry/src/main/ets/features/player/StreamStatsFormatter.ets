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

import { pasteboard } from '@kit.BasicServicesKit';
import { UIContext } from '@kit.ArkUI';
import { resourceManager } from '@kit.LocalizationKit';
import { PlaybackStats, PlayerUiViewModel } from 'mediaservice';
import { formatBytes, formatDurationHms } from '../../common/utils/FormatUtils';
import { AppLog } from '../../common/AppLog';

export type AvSyncSeverity = 'normal' | 'warn' | 'bad';

export interface StreamStatsLabels {
  softwareDecode: string;
  transportDirect: string;
  transportLocal: string;
  fxNormalize: string;
  fxNone: string;
}

export interface DiagnosticSnapshotInput {
  videoId: string;
  vm: PlayerUiViewModel;
  stats: PlaybackStats | null;
  audioDelayMs: number;
  labels: StreamStatsLabels;
}

function readStringSafe(rm: resourceManager.ResourceManager | undefined, res: Resource, fallback: string): string {
  if (!rm) {
    return fallback;
  }
  try {
    return rm.getStringSync(res.id);
  } catch (_e) {
    return fallback;
  }
}

export function resolveStreamStatsLabels(rm: resourceManager.ResourceManager | undefined): StreamStatsLabels {
  return {
    softwareDecode: readStringSafe(rm, $r('app.string.yt_stats_sw_decode'), 'Software'),
    transportDirect: readStringSafe(rm, $r('app.string.yt_stats_transport_direct'), 'Direct'),
    transportLocal: readStringSafe(rm, $r('app.string.yt_stats_transport_local'), 'Local'),
    fxNormalize: readStringSafe(rm, $r('app.string.yt_playback_audio_normalize'), 'Normalize'),
    fxNone: readStringSafe(rm, $r('app.string.yt_stats_none'), 'None')
  };
}

export function formatTransportSummary(
  transportKind: string,
  endpoint: string,
  videoItag: number,
  audioItag: number,
  labels: StreamStatsLabels
): string {
  const kind: string = transportKind.trim().toLowerCase();
  const ep: string = endpoint.trim();

  let transportLabel: string = '';
  if (kind === 'sabr') {
    transportLabel = 'SABR';
  } else if (kind === 'ypstream') {
    transportLabel = labels.transportDirect;
  } else if (kind === 'hls') {
    transportLabel = 'HLS';
  } else if (kind === 'local') {
    transportLabel = labels.transportLocal;
  } else if (kind === 'http') {
    transportLabel = 'HTTP';
  }

  let base: string = '';
  if (kind === 'local') {
    base = labels.transportLocal;
  } else if (ep.length > 0 && transportLabel.length > 0) {
    base = `${ep} · ${transportLabel}`;
  } else if (transportLabel.length > 0) {
    base = transportLabel;
  } else if (ep.length > 0) {
    base = ep;
  }

  let itagPart: string = '';
  if (videoItag > 0 && audioItag > 0) {
    itagPart = `(v${videoItag} / a${audioItag})`;
  } else if (videoItag > 0) {
    itagPart = `(v${videoItag})`;
  } else if (audioItag > 0) {
    itagPart = `(a${audioItag})`;
  }

  if (base.length > 0 && itagPart.length > 0) {
    return `${base} ${itagPart}`;
  }
  if (base.length > 0) {
    return base;
  }
  if (itagPart.length > 0) {
    return itagPart;
  }
  return '';
}

export function formatHwdec(hwdec: string, softwareLabel: string): string {
  const trimmed: string = hwdec.trim();
  const lower: string = trimmed.toLowerCase();
  if (trimmed.length === 0 || lower === 'no' || lower === 'none') {
    return softwareLabel;
  }
  return trimmed;
}

export function isHdrGamma(colorGamma: string): boolean {
  const g: string = colorGamma.trim().toLowerCase();
  return g === 'pq' || g === 'hlg' || g === 'smpte2084' || g === 'arib-std-b67';
}

export function formatColorInfo(
  pixelFormat: string,
  colorSpace: string,
  colorPrimaries: string,
  colorGamma: string
): string {
  const pix: string = pixelFormat.trim();
  const space: string = colorSpace.trim();
  const primaries: string = colorPrimaries.trim();
  const gamma: string = colorGamma.trim();

  const colorMain: string = space.length > 0 ? space : primaries;
  let colorPart: string = '';
  if (colorMain.length > 0 && gamma.length > 0) {
    colorPart = `${colorMain} / ${gamma}`;
  } else if (colorMain.length > 0) {
    colorPart = colorMain;
  } else if (gamma.length > 0) {
    colorPart = gamma;
  }

  const parts: string[] = [];
  if (pix.length > 0) {
    parts.push(pix);
  }
  if (colorPart.length > 0) {
    parts.push(colorPart);
  }
  if (isHdrGamma(gamma)) {
    parts.push('HDR');
  }
  return parts.join(' · ');
}

export function formatFrameRateSummary(containerFps: number, measuredFps: number): string {
  const hasContainer: boolean = Number.isFinite(containerFps) && containerFps > 0;
  const hasMeasured: boolean = Number.isFinite(measuredFps) && measuredFps > 0.5;
  if (hasContainer && hasMeasured) {
    return `${containerFps.toFixed(2)} fps (${measuredFps.toFixed(1)})`;
  }
  if (hasContainer) {
    return `${containerFps.toFixed(2)} fps`;
  }
  if (hasMeasured) {
    return `${measuredFps.toFixed(1)} fps`;
  }
  return '';
}

export function formatAvSync(avSyncMs: number | undefined): string {
  if (avSyncMs === undefined || !Number.isFinite(avSyncMs)) {
    return '--';
  }
  const normalized: number = Math.abs(avSyncMs) < 0.05 ? 0 : avSyncMs;
  const sign: string = normalized >= 0 ? '+' : '';
  return `${sign}${normalized.toFixed(1)} ms`;
}

export function getAvSyncSeverity(avSyncMs: number | undefined): AvSyncSeverity {
  if (avSyncMs === undefined || !Number.isFinite(avSyncMs)) {
    return 'normal';
  }
  const abs: number = Math.abs(avSyncMs);
  if (abs >= 80) {
    return 'bad';
  }
  if (abs >= 40) {
    return 'warn';
  }
  return 'normal';
}

export function formatDroppedFrames(dropped: number, decoderDropped: number, totalFrames: number): string {
  const vo: number = Number.isFinite(dropped) ? Math.max(0, Math.floor(dropped)) : 0;
  const dec: number = Number.isFinite(decoderDropped) ? Math.max(0, Math.floor(decoderDropped)) : 0;
  const total: number = Number.isFinite(totalFrames) ? Math.max(0, Math.floor(totalFrames)) : 0;
  if (vo === 0 && dec === 0) {
    return total > 0 ? `0 / ${total}` : '0';
  }
  return total > 0 ? `${vo} VO + ${dec} Dec / ${total}` : `${vo} VO + ${dec} Dec`;
}

export function formatBufferSummary(bufferSec: number, bufferedBytes: number): string {
  const sec: number = Number.isFinite(bufferSec) ? Math.max(0, bufferSec) : 0;
  const secStr: string = `${sec.toFixed(1)} s`;
  if (Number.isFinite(bufferedBytes) && bufferedBytes > 0) {
    const bytesStr: string = formatBytes(bufferedBytes);
    if (bytesStr.length > 0) {
      return `${secStr} (${bytesStr})`;
    }
  }
  return secStr;
}

export function formatSpeedBps(bps: number): string {
  if (!Number.isFinite(bps) || bps <= 0) {
    return '0.00 KB/s';
  }
  if (bps >= 1024 * 1024) {
    return `${(bps / (1024 * 1024)).toFixed(2)} MB/s`;
  }
  return `${(bps / 1024).toFixed(2)} KB/s`;
}

export function formatBitrateBps(bps: number): string {
  if (!Number.isFinite(bps) || bps <= 0) {
    return '';
  }
  if (bps >= 1000000) {
    return `${(bps / 1000000).toFixed(2)} Mbps`;
  }
  if (bps >= 1000) {
    return `${(bps / 1000).toFixed(0)} kbps`;
  }
  return `${Math.round(bps)} bps`;
}

export function formatAudioChannelsShort(channels: number, channelLayout: string): string {
  const layout: string = channelLayout.trim();
  if (layout.length > 0) {
    return layout;
  }
  if (channels === 1) {
    return 'Mono (1.0)';
  }
  if (channels === 2) {
    return 'Stereo (2.0)';
  }
  if (channels === 6) {
    return '5.1';
  }
  if (channels === 8) {
    return '7.1';
  }
  return channels > 0 ? `${channels} ch` : '';
}

export function formatAudioFormatLine(audioFormat: string, channelLayout: string, channels: number): string {
  const parts: string[] = [];
  const fmt: string = audioFormat.trim();
  if (fmt.length > 0) {
    parts.push(fmt);
  }
  const layout: string = channelLayout.trim();
  if (layout.length > 0) {
    parts.push(layout);
  } else if (channels > 0 && parts.length > 0) {
    parts.push(formatAudioChannelsShort(channels, ''));
  }
  return parts.join(' · ');
}

export function formatAudioFxSummary(
  activeAudioFilters: string,
  audioDelayMs: number,
  labels: StreamStatsLabels
): string {
  const parts: string[] = [];
  const trimmed: string = activeAudioFilters.trim();
  const lower: string = trimmed.toLowerCase();
  if (lower.includes('acompressor') || lower.includes('dynaudnorm') || lower.includes('loudnorm')) {
    parts.push(labels.fxNormalize);
  }
  if (trimmed.length > 0 && parts.length === 0) {
    parts.push(trimmed);
  }
  if (Number.isFinite(audioDelayMs) && Math.round(audioDelayMs) !== 0) {
    const rounded: number = Math.round(audioDelayMs);
    parts.push(`${rounded > 0 ? '+' : ''}${rounded} ms`);
  }
  return parts.join(' · ');
}

export function buildDiagnosticReport(input: DiagnosticSnapshotInput): string {
  const vm: PlayerUiViewModel = input.vm;
  const stats: PlaybackStats | null = input.stats;
  const labels: StreamStatsLabels = input.labels;
  const lines: string[] = ['YourPipe Playback Diagnostics'];

  if (input.videoId.trim().length > 0) {
    lines.push(`Video ID: ${input.videoId.trim()}`);
  }
  const transport: string = formatTransportSummary(
    stats ? stats.transportKind : '',
    vm.currentStreamEndpoint,
    vm.currentVideoItag,
    vm.currentAudioItag,
    labels
  );
  if (transport.length > 0) {
    lines.push(`Transport: ${transport}`);
  }

  const metaParts: string[] = [];
  if (vm.containerFormat.length > 0) {
    metaParts.push(`Container: ${vm.containerFormat.toUpperCase()}`);
  }
  if (vm.durationTime > 0) {
    metaParts.push(`Duration: ${formatDurationHms(vm.durationTime)}`);
  }
  if (vm.fileSize > 0) {
    const sz: string = formatBytes(vm.fileSize);
    if (sz.length > 0) {
      metaParts.push(`Size: ${sz}`);
    }
  }
  if (metaParts.length > 0) {
    lines.push(metaParts.join(' | '));
  }

  if (vm.videoWidth > 0) {
    const videoParts: string[] = [`${vm.videoWidth}x${vm.videoHeight}`];
    const fpsStr: string = formatFrameRateSummary(vm.frameRate, stats ? stats.measuredFps : 0);
    if (fpsStr.length > 0) {
      videoParts.push(`@ ${fpsStr}`);
    }
    if (vm.videoCodec.length > 0) {
      const br: string = formatBitrateBps(vm.videoBitRate);
      videoParts.push(br.length > 0 ? `${vm.videoCodec} (${br})` : vm.videoCodec);
    }
    lines.push(`Video: ${videoParts.join(' · ')}`);

    const hw: string = formatHwdec(vm.hwdec, labels.softwareDecode);
    const color: string = formatColorInfo(vm.pixelFormat, vm.colorSpace, vm.colorPrimaries, vm.colorGamma);
    lines.push(color.length > 0 ? `Decoder: ${hw} | Color: ${color}` : `Decoder: ${hw}`);
  }

  if (vm.audioCodec.length > 0 || vm.audioSampleRate > 0) {
    const audioParts: string[] = [];
    if (vm.audioCodec.length > 0) {
      const abr: string = formatBitrateBps(vm.audioBitRate);
      audioParts.push(abr.length > 0 ? `${vm.audioCodec} (${abr})` : vm.audioCodec);
    }
    if (vm.audioSampleRate > 0) {
      audioParts.push(`${(vm.audioSampleRate / 1000).toFixed(1)} kHz`);
    }
    const chStr: string = formatAudioFormatLine(vm.audioFormat, vm.audioChannelLayout, vm.audioChannels)
      || formatAudioChannelsShort(vm.audioChannels, vm.audioChannelLayout);
    if (chStr.length > 0) {
      audioParts.push(chStr);
    }
    lines.push(`Audio: ${audioParts.join(' · ')}`);
  }

  if (stats !== null) {
    const avSync: string = formatAvSync(stats.avSyncMs);
    const dropped: string = formatDroppedFrames(stats.droppedFrames, stats.decoderDroppedFrames, stats.totalFrames);
    lines.push(`A/V Sync: ${avSync} | Dropped: ${dropped}`);

    const buf: string = formatBufferSummary(stats.demuxerCacheDurationSec, stats.bufferedBytes);
    const speed: string = formatSpeedBps(stats.networkSpeedBps ?? 0);
    lines.push(`Buffer: ${buf} | Speed: ${speed}`);

    const fx: string = formatAudioFxSummary(stats.activeAudioFilters, input.audioDelayMs, labels);
    lines.push(`Audio FX: ${fx.length > 0 ? fx : labels.fxNone}`);
  }

  return lines.join('\n');
}

export function copyDiagnosticsToClipboard(uiContext: UIContext, text: string, logTag: string): void {
  const logger = AppLog.getInstance(logTag);
  const pasteboardData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  const systemPasteboard = pasteboard.getSystemPasteboard();
  systemPasteboard.setData(pasteboardData).then(() => {
    uiContext.getPromptAction().showToast({ message: $r('app.string.yt_toast_copied'), duration: 2000 });
    logger.info(`diagnostics copied chars=${text.length}`);
  }).catch((error: Error) => {
    uiContext.getPromptAction().showToast({ message: $r('app.string.yt_toast_copy_failed'), duration: 2000 });
    logger.error(`diagnostics copy failed error=${error.message}`);
  });
}
