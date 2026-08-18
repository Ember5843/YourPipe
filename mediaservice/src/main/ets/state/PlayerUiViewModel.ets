/*
 * PlayerUiViewModel —— UI 层观察的播放器响应式状态。
 *
 * AvPlayerController 持有此对象（@Track public readonly vm），引擎事件回调
 * 写入这里的字段，UI 通过 controller.vm.xxx 订阅。命令仍走 controller 自身。
 *
 * 这一层把"响应式 UI 状态"与"播放控制"两类职责分开：
 *   - controller —— 命令、流程编排、状态机驱动
 *   - vm         —— @Observed/@Track 字段，仅供 UI 订阅
 */

import { PlayerModel } from '../model/PlayerModel';
import { SubtitleTrack } from 'youtube_core';

@Observed
export class PlayerUiViewModel {
  @Track isPlaying: boolean = false;
  @Track isReady: boolean = false;
  @Track isBuffering: boolean = false;
  /** True from quality/audio menu click until new source is ready — forces spinner even before engine load. */
  @Track isSourceSwitching: boolean = false;
  @Track isSeeking: boolean = false;
  @Track isEnded: boolean = false;
  @Track currentTime: number = 0;
  @Track durationTime: number = 0;
  @Track errorMsg: string = '';
  /** Terminal error shown in player UI (transient recovery errors stay off this field). */
  @Track userVisibleErrorMsg: string = '';
  @Track cachedPercent: number = 0;
  @Track seekableRanges: number[][] = [];
  @Track playbackSpeed: number = 1.0;
  @Track playerModel: PlayerModel = new PlayerModel();
  @Track subtitleTracks: SubtitleTrack[] = [];
  @Track currentSubtitleUrl: string = '';
  @Track subtitleText: string = '';
  @Track isCasting: boolean = false;
  @Track castDeviceName: string = '';
  // 当前实际播放流的实时信息（由 mpv getMediaInfo 提供）
  @Track mediaTitle: string = '';
  @Track containerFormat: string = '';
  @Track videoWidth: number = 0;
  @Track videoHeight: number = 0;
  @Track videoStreamCount: number = 0;
  @Track audioStreamCount: number = 0;
  @Track subtitleStreamCount: number = 0;
  @Track videoCodec: string = '';
  @Track videoBitRate: number = 0;
  @Track frameRate: number = 0;
  @Track audioCodec: string = '';
  @Track audioBitRate: number = 0;
  @Track audioChannels: number = 0;
  @Track audioSampleRate: number = 0;
  @Track fileSize: number = 0;

  public reset(): void {
    this.isPlaying = false;
    this.isReady = false;
    this.isBuffering = false;
    this.isSourceSwitching = false;
    this.isSeeking = false;
    this.isEnded = false;
    this.currentTime = 0;
    this.durationTime = 0;
    this.errorMsg = '';
    this.userVisibleErrorMsg = '';
    this.cachedPercent = 0;
    this.seekableRanges = [];
    this.playbackSpeed = 1.0;
    this.subtitleTracks = [];
    this.currentSubtitleUrl = '';
    this.subtitleText = '';
    this.mediaTitle = '';
    this.containerFormat = '';
    this.videoWidth = 0;
    this.videoHeight = 0;
    this.videoStreamCount = 0;
    this.audioStreamCount = 0;
    this.subtitleStreamCount = 0;
    this.videoCodec = '';
    this.videoBitRate = 0;
    this.frameRate = 0;
    this.audioCodec = '';
    this.audioBitRate = 0;
    this.audioChannels = 0;
    this.audioSampleRate = 0;
    this.fileSize = 0;
  }
}
