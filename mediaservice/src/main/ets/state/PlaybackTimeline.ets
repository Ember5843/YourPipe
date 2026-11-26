import { PlaybackState } from '../engine/PlaybackEngine';

/** One timeline for the VM, progress subscribers and AVSession during a same-media reload. */
export function normalizePlaybackTimeline(state: PlaybackState, position: number, duration: number): PlaybackState {
  if (state.isReady || duration <= 0 || (state.currentTime > 0 && state.duration > 0)) return state;
  return {
    engineState: state.engineState, isPlaying: state.isPlaying, isReady: state.isReady,
    isBuffered: state.isBuffered, isBuffering: state.isBuffering, isSeeking: state.isSeeking,
    isEnded: state.isEnded, isLive: state.isLive, isSeekable: state.isSeekable,
    currentTime: state.currentTime > 0 ? state.currentTime : position,
    duration: state.duration > 0 ? state.duration : duration,
    playbackSpeed: state.playbackSpeed, bufferingPercent: state.bufferingPercent,
    seekableRanges: state.seekableRanges, uri: state.uri, mediaTitle: state.mediaTitle,
    containerFormat: state.containerFormat, videoWidth: state.videoWidth, videoHeight: state.videoHeight,
    videoStreamCount: state.videoStreamCount, audioStreamCount: state.audioStreamCount,
    subtitleStreamCount: state.subtitleStreamCount, videoCodec: state.videoCodec,
    videoBitRate: state.videoBitRate, frameRate: state.frameRate,
    hwdec: state.hwdec, pixelFormat: state.pixelFormat, colorSpace: state.colorSpace,
    colorPrimaries: state.colorPrimaries, colorGamma: state.colorGamma,
    audioCodec: state.audioCodec, audioBitRate: state.audioBitRate,
    audioChannels: state.audioChannels, audioSampleRate: state.audioSampleRate,
    audioFormat: state.audioFormat, audioChannelLayout: state.audioChannelLayout,
    fileSize: state.fileSize, errorMsg: state.errorMsg,
    errorCategory: state.errorCategory, errorCode: state.errorCode
  };
}
