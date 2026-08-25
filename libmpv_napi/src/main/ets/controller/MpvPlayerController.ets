import nativeModule from 'libmpv_napi.so';
import { PlaybackState } from '../enums';
import type { MediaInfo } from '../media-info';

function createPlayerId(): string {
  const now = Date.now();
  const randomPart = Math.floor(Math.random() * 1000000);
  return `mpv_${now}_${randomPart}`;
}

export class MpvPlayerController {
  public readonly playerId: string;

  constructor(playerId?: string) {
    this.playerId = playerId ?? createPlayerId();
  }

  setMedia(url: string, startPositionMs: number = 0): void {
    nativeModule.setMedia(this.playerId, url, startPositionMs);
  }

  play(): void {
    nativeModule.play(this.playerId);
  }

  pause(): void {
    nativeModule.pause(this.playerId);
  }

  stop(): void {
    nativeModule.stop(this.playerId);
  }

  prepare(startPosition: number = 0): void {
    nativeModule.prepare(this.playerId, startPosition);
  }

  seek(positionMs: number): void {
    nativeModule.seekWithFlags(this.playerId, positionMs);
  }

  setPlaybackRate(rate: number): void {
    nativeModule.setPlaybackRate(this.playerId, rate);
  }

  setVolume(volume: number): void {
    nativeModule.setVolume(this.playerId, volume);
  }

  setProperty(key: string, value: string): void {
    nativeModule.setProperty(this.playerId, key, value);
  }

  getProperty(key: string): string {
    return nativeModule.getProperty(this.playerId, key);
  }

  getPosition(): number {
    return nativeModule.getPosition(this.playerId);
  }

  getDuration(): number {
    return nativeModule.getDuration(this.playerId);
  }

  getSeekableRangesJson(): string {
    return nativeModule.getSeekableRangesJson(this.playerId);
  }

  getState(): PlaybackState {
    return nativeModule.getState(this.playerId);
  }

  getMediaInfo(): MediaInfo {
    return nativeModule.getMediaInfo(this.playerId);
  }

  setVideoSurfaceSize(width: number, height: number): void {
    nativeModule.setVideoSurfaceSize(this.playerId, width, height);
  }

  setVideoSurfaceId(surfaceId: string): void {
    nativeModule.setVideoSurfaceId(this.playerId, surfaceId);
  }

  setEventCallback(callback: (type: number, value: number) => void): void {
    nativeModule.setEventCallback(this.playerId, callback);
  }

  command(args: string[]): void {
    nativeModule.command(this.playerId, args);
  }

  dispose(): void {
    nativeModule.releasePlayer(this.playerId);
  }
}

export type { MediaInfo };
