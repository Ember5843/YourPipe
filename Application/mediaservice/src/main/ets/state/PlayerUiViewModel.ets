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
  @Track isSeeking: boolean = false;
  @Track isEnded: boolean = false;
  @Track currentTime: number = 0;
  @Track duration: number = 0;
  @Track durationTime: number = 0;
  @Track errorMsg: string = '';
  @Track cachedPercent: number = 0;
  @Track seekableRanges: number[][] = [];
  @Track playbackSpeed: number = 1.0;
  @Track playerModel: PlayerModel = new PlayerModel();
  @Track subtitleTracks: SubtitleTrack[] = [];
  @Track currentSubtitleUrl: string = '';
  @Track subtitleText: string = '';
  @Track isCasting: boolean = false;
  @Track castDeviceName: string = '';

  public reset(): void {
    this.isPlaying = false;
    this.isReady = false;
    this.isBuffering = false;
    this.isSeeking = false;
    this.isEnded = false;
    this.currentTime = 0;
    this.duration = 0;
    this.durationTime = 0;
    this.errorMsg = '';
    this.cachedPercent = 0;
    this.seekableRanges = [];
    this.playbackSpeed = 1.0;
    this.subtitleTracks = [];
    this.currentSubtitleUrl = '';
    this.subtitleText = '';
  }
}
