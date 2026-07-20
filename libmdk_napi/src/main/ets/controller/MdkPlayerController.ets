import nativeModule from 'libmdk_napi.so';
import { ColorSpace, MediaStatus, MediaType, PlaybackState, SeekFlag, VideoEffect } from '../enums';
import type { MediaInfo } from '../media-info';

type EventHandler = (value: number) => void;

function createPlayerId(): string {
  const now = Date.now();
  const randomPart = Math.floor(Math.random() * 1000000);
  return `mdk_${now}_${randomPart}`;
}

export class MdkPlayerController {
  public readonly playerId: string;
  private eventHandlers: Map<string, EventHandler[]> = new Map();

  constructor(playerId?: string) {
    this.playerId = playerId ?? createPlayerId();
  }

  on(event: string, handler: EventHandler): void {
    if (!this.eventHandlers.has(event)) this.eventHandlers.set(event, []);
    this.eventHandlers.get(event)!.push(handler);
  }

  off(event: string, handler: EventHandler): void {
    const handlers = this.eventHandlers.get(event);
    if (handlers) {
      const index = handlers.indexOf(handler);
      if (index !== -1) handlers.splice(index, 1);
    }
  }

  emit(event: string, value: number): void {
    this.eventHandlers.get(event)?.forEach(h => h(value));
  }

  setMedia(url: string, startPositionMs: number = 0): void {
    nativeModule.setMedia(this.playerId, url, startPositionMs);
  }

  setMediaSource(url: string, mediaType: MediaType): void {
    nativeModule.setMediaSource(this.playerId, url, mediaType);
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

  seek(positionMs: number, flags: SeekFlag = SeekFlag.Default): void {
    nativeModule.seekWithFlags(this.playerId, positionMs, flags);
  }

  setPlaybackRate(rate: number): void {
    nativeModule.setPlaybackRate(this.playerId, rate);
  }

  setVolume(volume: number): void {
    nativeModule.setVolume(this.playerId, volume);
  }

  setLoop(count: number): void {
    nativeModule.setLoop(this.playerId, count);
  }

  setProperty(key: string, value: string): void {
    nativeModule.setProperty(this.playerId, key, value);
  }

  getProperty(key: string): string {
    return nativeModule.getProperty(this.playerId, key);
  }

  setColorSpace(colorSpace: ColorSpace): void {
    nativeModule.setColorSpace(this.playerId, colorSpace);
  }

  setVideoEffect(effect: VideoEffect, value: number): void {
    nativeModule.setVideoEffect(this.playerId, effect, value);
  }

  setDecoders(names: string[], mediaType: MediaType = MediaType.Video): void {
    nativeModule.setDecoders(this.playerId, mediaType, names);
  }

  setActiveTracks(tracks: number[], mediaType: MediaType): void {
    nativeModule.setActiveTracks(this.playerId, mediaType, tracks);
  }

  setAudioBackends(names: string[]): void {
    nativeModule.setAudioBackends(this.playerId, names);
  }

  getPosition(): number {
    return nativeModule.getPosition(this.playerId);
  }

  getDuration(): number {
    return nativeModule.getDuration(this.playerId);
  }

  buffered(): number {
    return nativeModule.buffered(this.playerId);
  }

  getSeekableRangesJson(): string {
    return nativeModule.getSeekableRangesJson(this.playerId);
  }

  getState(): PlaybackState {
    return nativeModule.getState(this.playerId);
  }

  getMediaStatus(): MediaStatus {
    return nativeModule.getMediaStatus(this.playerId);
  }

  getMediaInfo(): MediaInfo {
    return nativeModule.getMediaInfo(this.playerId);
  }

  isPlaying(): boolean {
    return nativeModule.isPlaying(this.playerId);
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

export {
  ColorSpace,
  MediaStatus,
  MediaType,
  PlaybackState,
  SeekFlag,
  VideoEffect,
};
export type { MediaInfo };
