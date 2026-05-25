import { ItagItem } from './itag/ItagItem';

/**
 * Class to build easier Streams for YoutubeStreamExtractor.
 * Ported from org.schabi.newpipe.extractor.services.youtube.extractors.ItagInfo
 *
 * It stores, per stream:
 * - its content (the URL/the base URL of streams);
 * - whether its content is the URL the content itself or the base URL;
 * - its associated ItagItem;
 * - optionally, an obfuscated signature for batch deobfuscation.
 */
export class ItagInfo {
  private contentVal: string;
  private readonly itagItemVal: ItagItem;
  private isUrlVal: boolean = false;
  private obfuscatedSignatureVal: string | undefined;
  private audioTrackIdVal: string | undefined;
  private audioTrackNameVal: string | undefined;
  private audioLocaleVal: string | undefined;

  constructor(content: string, itagItem: ItagItem) {
    this.contentVal = content;
    this.itagItemVal = itagItem;
  }

  setIsUrl(isUrl: boolean): void {
    this.isUrlVal = isUrl;
  }

  setContent(content: string): void {
    this.contentVal = content;
  }

  setObfuscatedSignature(obfuscatedSignature: string | undefined): void {
    this.obfuscatedSignatureVal = obfuscatedSignature;
  }

  getObfuscatedSignature(): string | undefined {
    return this.obfuscatedSignatureVal;
  }

  getContent(): string {
    return this.contentVal;
  }

  getItagItem(): ItagItem {
    return this.itagItemVal;
  }

  getIsUrl(): boolean {
    return this.isUrlVal;
  }

  setAudioTrackInfo(audioTrackId: string | undefined, audioTrackName: string | undefined, audioLocale: string | undefined): void {
    this.audioTrackIdVal = audioTrackId;
    this.audioTrackNameVal = audioTrackName;
    this.audioLocaleVal = audioLocale;
  }

  getAudioTrackId(): string | undefined {
    return this.audioTrackIdVal;
  }

  getAudioTrackName(): string | undefined {
    return this.audioTrackNameVal;
  }

  getAudioLocale(): string | undefined {
    return this.audioLocaleVal;
  }
}
