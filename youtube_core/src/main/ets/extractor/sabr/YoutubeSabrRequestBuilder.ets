import { SabrBufferedRange } from './SabrBufferedRange';
import { SabrProtocolException } from './SabrProtocolException';
import {
  decodeBase64ToBytes,
  parseLastModified,
  sabrFormatIdBytes,
  SabrProtoWriter
} from './SabrProto';
import { YoutubeSabrFormatMeta, YoutubeSabrInfo } from './YoutubeSabrInfo';
import {
  SABR_TRACK_BOTH,
  YoutubeSabrStreamState
} from './YoutubeSabrStreamState';

export class YoutubeSabrRequestBuilder {
  static buildFirstMediaRequest(
    info: YoutubeSabrInfo,
    audioFormat: YoutubeSabrFormatMeta,
    videoFormat: YoutubeSabrFormatMeta,
    streamState?: YoutubeSabrStreamState
  ): Uint8Array {
    const ustreamerConfig = info.videoPlaybackUstreamerConfig;
    if (!ustreamerConfig) {
      throw new SabrProtocolException('Missing video playback ustreamer config');
    }
    const playerTimeMs = streamState ? streamState.getRequestPlayerTimeMs() : 0;
    const bufferedRanges: SabrBufferedRange[] = streamState
      ? streamState.getBufferedRanges()
      : [];
    const includeInitialPlaybackState = playerTimeMs > 0 || bufferedRanges.length > 0;
    const request = new SabrProtoWriter();
    request.writeMessage(1, YoutubeSabrRequestBuilder.buildClientAbrState(
      audioFormat, videoFormat, playerTimeMs, includeInitialPlaybackState,
      streamState ? streamState.getEnabledTrackTypesBitfield() : SABR_TRACK_BOTH,
      streamState
    ));
    if (includeInitialPlaybackState && streamState) {
      if (streamState.shouldSelectVideoFormat() && streamState.isInitialized(videoFormat)) {
        request.writeMessage(2, sabrFormatIdBytes(videoFormat));
      }
      if (streamState.shouldSelectAudioFormat() && streamState.isInitialized(audioFormat)) {
        request.writeMessage(2, sabrFormatIdBytes(audioFormat));
      }
      for (const range of bufferedRanges) {
        request.writeMessage(3, range.toProto(true));
      }
      if (streamState.shouldWriteTopLevelPlayerTimeMs()) {
        request.writeUInt64(4, playerTimeMs);
      }
    }
    request.writeBytes(5, decodeBase64ToBytes(ustreamerConfig));
    YoutubeSabrRequestBuilder.writePreferredFormats(
      request, audioFormat, videoFormat, streamState);
    request.writeMessage(19, YoutubeSabrRequestBuilder.buildStreamerContext(info, streamState));
    return request.toUint8Array();
  }

  static buildFollowUpMediaRequest(
    info: YoutubeSabrInfo,
    audioFormat: YoutubeSabrFormatMeta,
    videoFormat: YoutubeSabrFormatMeta,
    streamState: YoutubeSabrStreamState
  ): Uint8Array {
    const ustreamerConfig = info.videoPlaybackUstreamerConfig;
    if (!ustreamerConfig) {
      throw new SabrProtocolException('Missing video playback ustreamer config');
    }
    const playerTimeMs = streamState.getRequestPlayerTimeMs();
    const request = new SabrProtoWriter();
    request.writeMessage(1, YoutubeSabrRequestBuilder.buildClientAbrState(
      audioFormat, videoFormat, playerTimeMs, true,
      streamState.getEnabledTrackTypesBitfield(), streamState
    ));
    if (streamState.shouldSelectVideoFormat() && streamState.isInitialized(videoFormat)) {
      request.writeMessage(2, sabrFormatIdBytes(videoFormat));
    }
    if (streamState.shouldSelectAudioFormat() && streamState.isInitialized(audioFormat)) {
      request.writeMessage(2, sabrFormatIdBytes(audioFormat));
    }
    for (const range of streamState.getBufferedRanges()) {
      request.writeMessage(3, range.toProto(true));
    }
    if (streamState.shouldWriteTopLevelPlayerTimeMs()) {
      request.writeUInt64(4, playerTimeMs);
    }
    request.writeBytes(5, decodeBase64ToBytes(ustreamerConfig));
    YoutubeSabrRequestBuilder.writePreferredFormats(
      request, audioFormat, videoFormat, streamState);
    request.writeMessage(19, YoutubeSabrRequestBuilder.buildStreamerContext(info, streamState));
    return request.toUint8Array();
  }

  private static buildClientAbrState(
    audioFormat: YoutubeSabrFormatMeta,
    videoFormat: YoutubeSabrFormatMeta,
    playerTimeMs: number,
    includeFollowUpState: boolean,
    enabledTrackTypesBitfield: number,
    streamState?: YoutubeSabrStreamState
  ): Uint8Array {
    const state = new SabrProtoWriter();
    if (includeFollowUpState) {
      state.writeInt32(18, Math.max(videoFormat.width ?? 0, 640));
      state.writeInt32(19, Math.max(videoFormat.height ?? 0, 360));
    }
    state.writeInt32(21, Math.max(videoFormat.height ?? 0, 360));
    if (includeFollowUpState) {
      const audioBr = audioFormat.bitrate ?? 0;
      const videoBr = videoFormat.bitrate ?? 0;
      if (audioBr > 0 && videoBr > 0) {
        state.writeUInt64(23, (audioBr + videoBr) * 2);
      }
    }
    state.writeInt32(34, 1);
    state.writeFloat(35, streamState ? streamState.getPlaybackRate() : 1.0);
    if (enabledTrackTypesBitfield !== SABR_TRACK_BOTH) {
      state.writeInt32(40, enabledTrackTypesBitfield);
    }
    state.writeUInt64(28, playerTimeMs);
    if (audioFormat.audioTrackId) {
      state.writeStringIfNotEmpty(69, audioFormat.audioTrackId);
    }
    return state.toUint8Array();
  }

  private static writePreferredFormats(
    request: SabrProtoWriter,
    audioFormat: YoutubeSabrFormatMeta,
    videoFormat: YoutubeSabrFormatMeta,
    streamState?: YoutubeSabrStreamState
  ): void {
    if (!streamState || streamState.shouldSelectAudioFormat()) {
      request.writeMessage(16, sabrFormatIdBytes(audioFormat));
    }
    if (!streamState || streamState.shouldSelectVideoFormat()) {
      request.writeMessage(17, sabrFormatIdBytes(videoFormat));
    }
  }

  private static buildStreamerContext(
    info: YoutubeSabrInfo,
    streamState?: YoutubeSabrStreamState
  ): Uint8Array {
    const context = new SabrProtoWriter();
    context.writeMessage(1, YoutubeSabrRequestBuilder.buildClientInfo(info));
    if (streamState) {
      const poToken = streamState.getRawPoToken();
      if (poToken && poToken.length > 0) {
        context.writeBytes(2, poToken);
      }
      const cookie = streamState.getRawPlaybackCookie();
      if (cookie && cookie.length > 0) {
        context.writeBytes(3, cookie);
      }
      for (const update of streamState.getActiveSabrContexts()) {
        const msg = new SabrProtoWriter();
        msg.writeInt32(1, update.type);
        msg.writeBytes(2, update.value);
        context.writeMessage(5, msg.toUint8Array());
      }
      for (const type of streamState.getUnsentSabrContextTypes()) {
        context.writeInt32(6, type);
      }
    }
    return context.toUint8Array();
  }

  private static buildClientInfo(info: YoutubeSabrInfo): Uint8Array {
    const client = new SabrProtoWriter();
    const clientId = info.profile === 'web' ? 1 : 2;
    client.writeInt32(16, clientId);
    client.writeStringIfNotEmpty(17, info.clientVersion);
    client.writeStringIfNotEmpty(21, 'en-US');
    client.writeStringIfNotEmpty(22, 'US');
    return client.toUint8Array();
  }

  static withSabrSessionParameters(
    serverAbrStreamingUrl: string,
    cpn: string,
    requestNumber: number
  ): string {
    let url = serverAbrStreamingUrl;
    if (url.indexOf('alr=') < 0) {
      url += (url.indexOf('?') >= 0 ? '&' : '?') + 'alr=yes';
    }
    // Replace or append cpn / rn
    url = replaceOrAppendQuery(url, 'cpn', cpn);
    url = replaceOrAppendQuery(url, 'rn', String(requestNumber + 1));
    return url;
  }
}

function replaceOrAppendQuery(url: string, key: string, value: string): string {
  const re = new RegExp(`([?&])${key}=[^&]*`);
  if (re.test(url)) {
    return url.replace(re, `$1${key}=${encodeURIComponent(value)}`);
  }
  return url + (url.indexOf('?') >= 0 ? '&' : '?') + `${key}=${encodeURIComponent(value)}`;
}
