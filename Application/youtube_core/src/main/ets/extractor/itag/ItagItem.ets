import { MediaFormat } from './MediaFormat';

/**
 * Itag type enumeration
 * Ported from org.schabi.newpipe.extractor.services.youtube.ItagItem.ItagType
 */
export enum ItagType {
  AUDIO = 'AUDIO',
  VIDEO = 'VIDEO',
  VIDEO_ONLY = 'VIDEO_ONLY'
}

/**
 * Static constants
 */
export const AVERAGE_BITRATE_UNKNOWN = -1;
export const SAMPLE_RATE_UNKNOWN = -1;
export const FPS_NOT_APPLICABLE_OR_UNKNOWN = -1;
export const TARGET_DURATION_SEC_UNKNOWN = -1;
export const AUDIO_CHANNELS_NOT_APPLICABLE_OR_UNKNOWN = -1;
export const CONTENT_LENGTH_UNKNOWN = -1;
export const APPROX_DURATION_MS_UNKNOWN = -1;

/**
 * Itag item representation
 * Ported from org.schabi.newpipe.extractor.services.youtube.ItagItem
 */
export class ItagItem {
  /**
   * List can be found here:
   * https://github.com/ytdl-org/youtube-dl/blob/e988fa4/youtube_dl/extractor/youtube.py#L1195
   */
  private static readonly ITAG_LIST: ItagItem[] = [
    // VIDEO
    new ItagItem(17, ItagType.VIDEO, MediaFormat.v3GPP, '144p'),
    new ItagItem(36, ItagType.VIDEO, MediaFormat.v3GPP, '240p'),
    new ItagItem(18, ItagType.VIDEO, MediaFormat.MPEG_4, '360p'),
    new ItagItem(34, ItagType.VIDEO, MediaFormat.MPEG_4, '360p'),
    new ItagItem(35, ItagType.VIDEO, MediaFormat.MPEG_4, '480p'),
    new ItagItem(59, ItagType.VIDEO, MediaFormat.MPEG_4, '480p'),
    new ItagItem(78, ItagType.VIDEO, MediaFormat.MPEG_4, '480p'),
    new ItagItem(22, ItagType.VIDEO, MediaFormat.MPEG_4, '720p'),
    new ItagItem(37, ItagType.VIDEO, MediaFormat.MPEG_4, '1080p'),
    new ItagItem(38, ItagType.VIDEO, MediaFormat.MPEG_4, '1080p'),
    new ItagItem(43, ItagType.VIDEO, MediaFormat.WEBM, '360p'),
    new ItagItem(44, ItagType.VIDEO, MediaFormat.WEBM, '480p'),
    new ItagItem(45, ItagType.VIDEO, MediaFormat.WEBM, '720p'),
    new ItagItem(46, ItagType.VIDEO, MediaFormat.WEBM, '1080p'),

    // AUDIO
    new ItagItem(171, ItagType.AUDIO, MediaFormat.WEBMA, 128),
    new ItagItem(172, ItagType.AUDIO, MediaFormat.WEBMA, 256),
    new ItagItem(139, ItagType.AUDIO, MediaFormat.M4A, 48),
    new ItagItem(140, ItagType.AUDIO, MediaFormat.M4A, 128),
    new ItagItem(141, ItagType.AUDIO, MediaFormat.M4A, 256),
    new ItagItem(249, ItagType.AUDIO, MediaFormat.WEBMA_OPUS, 50),
    new ItagItem(250, ItagType.AUDIO, MediaFormat.WEBMA_OPUS, 70),
    new ItagItem(251, ItagType.AUDIO, MediaFormat.WEBMA_OPUS, 160),

    // VIDEO ONLY
    new ItagItem(160, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '144p'),
    new ItagItem(133, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '240p'),
    new ItagItem(134, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '360p'),
    new ItagItem(135, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '480p'),
    new ItagItem(212, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '480p'),
    new ItagItem(136, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '720p'),
    new ItagItem(298, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '720p60', 60),
    new ItagItem(137, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '1080p'),
    new ItagItem(299, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '1080p60', 60),
    new ItagItem(266, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '2160p'),

    new ItagItem(278, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '144p'),
    new ItagItem(242, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '240p'),
    new ItagItem(243, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '360p'),
    new ItagItem(244, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '480p'),
    new ItagItem(245, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '480p'),
    new ItagItem(246, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '480p'),
    new ItagItem(247, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '720p'),
    new ItagItem(248, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '1080p'),
    new ItagItem(271, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '1440p'),
    new ItagItem(272, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '2160p'),
    new ItagItem(302, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '720p60', 60),
    new ItagItem(303, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '1080p60', 60),
    new ItagItem(308, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '1440p60', 60),
    new ItagItem(313, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '2160p'),
    new ItagItem(315, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '2160p60', 60),

    // AV1
    new ItagItem(394, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '144p'),
    new ItagItem(395, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '240p'),
    new ItagItem(396, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '360p'),
    new ItagItem(397, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '480p'),
    new ItagItem(398, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '720p HFR'),
    new ItagItem(399, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '1080p HFR'),
    new ItagItem(400, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '1440p HFR'),
    new ItagItem(401, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '2160p HFR'),
    new ItagItem(402, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '4320p HFR'),

    // High bitrate AV1
    new ItagItem(698, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '720p HFR High'),
    new ItagItem(699, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '1080p HFR High'),
    new ItagItem(700, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '1440p HFR High'),
    new ItagItem(701, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '2160p HFR High'),
    new ItagItem(571, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '4320p HFR High'),
  ];

  static isSupported(itag: number): boolean {
    return ItagItem.ITAG_LIST.some(item => item.id === itag);
  }

  static getItag(itagId: number): ItagItem {
    const found = ItagItem.ITAG_LIST.find(item => item.id === itagId);
    if (!found) {
      throw new Error(`itag ${itagId} is not supported`);
    }
    return new ItagItem(found);
  }

  readonly id: number;
  readonly itagType: ItagType;
  readonly mediaFormat: MediaFormat;

  // Audio fields
  avgBitrate: number = AVERAGE_BITRATE_UNKNOWN;
  private sampleRateVal: number = SAMPLE_RATE_UNKNOWN;
  private audioChannelsVal: number = AUDIO_CHANNELS_NOT_APPLICABLE_OR_UNKNOWN;

  // Video fields
  resolutionString: string | undefined;
  fps: number = FPS_NOT_APPLICABLE_OR_UNKNOWN;

  // DASH fields
  private bitrateVal: number = 0;
  private widthVal: number = 0;
  private heightVal: number = 0;
  private initStartVal: number = 0;
  private initEndVal: number = 0;
  private indexStartVal: number = 0;
  private indexEndVal: number = 0;
  private qualityVal: string | undefined;
  private audioQualityVal: string | undefined;
  private codecVal: string | undefined;
  private targetDurationSecVal: number = TARGET_DURATION_SEC_UNKNOWN;
  private approxDurationMsVal: number = APPROX_DURATION_MS_UNKNOWN;
  private contentLengthVal: number = CONTENT_LENGTH_UNKNOWN;

  constructor(id: number, type: ItagType, format: MediaFormat, resolution: string, fps?: number);
  constructor(id: number, type: ItagType, format: MediaFormat, avgBitrate: number);
  constructor(copy: ItagItem);
  constructor(idOrCopy: number | ItagItem, type?: ItagType, format?: MediaFormat, resolutionOrBitrate?: string | number, fps?: number) {
    if (idOrCopy instanceof ItagItem) {
      const copy = idOrCopy;
      this.id = copy.id;
      this.itagType = copy.itagType;
      this.mediaFormat = copy.mediaFormat;
      this.avgBitrate = copy.avgBitrate;
      this.sampleRateVal = copy.sampleRateVal;
      this.audioChannelsVal = copy.audioChannelsVal;
      this.resolutionString = copy.resolutionString;
      this.fps = copy.fps;
      this.bitrateVal = copy.bitrateVal;
      this.widthVal = copy.widthVal;
      this.heightVal = copy.heightVal;
      this.initStartVal = copy.initStartVal;
      this.initEndVal = copy.initEndVal;
      this.indexStartVal = copy.indexStartVal;
      this.indexEndVal = copy.indexEndVal;
      this.qualityVal = copy.qualityVal;
      this.audioQualityVal = copy.audioQualityVal;
      this.codecVal = copy.codecVal;
      this.targetDurationSecVal = copy.targetDurationSecVal;
      this.approxDurationMsVal = copy.approxDurationMsVal;
      this.contentLengthVal = copy.contentLengthVal;
    } else {
      this.id = idOrCopy;
      this.itagType = type as ItagType;
      this.mediaFormat = format as MediaFormat;
      if (typeof resolutionOrBitrate === 'string') {
        this.resolutionString = resolutionOrBitrate;
        this.fps = fps ?? 30;
      } else if (typeof resolutionOrBitrate === 'number') {
        this.avgBitrate = resolutionOrBitrate;
      }
    }
  }

  getMediaFormat(): MediaFormat {
    return this.mediaFormat;
  }

  getBitrate(): number { return this.bitrateVal; }
  setBitrate(bitrate: number): void { this.bitrateVal = bitrate; }

  getWidth(): number { return this.widthVal; }
  setWidth(width: number): void { this.widthVal = width; }

  getHeight(): number { return this.heightVal; }
  setHeight(height: number): void { this.heightVal = height; }

  getFps(): number { return this.fps; }
  setFps(fps: number): void { this.fps = fps > 0 ? fps : FPS_NOT_APPLICABLE_OR_UNKNOWN; }

  getInitStart(): number { return this.initStartVal; }
  setInitStart(initStart: number): void { this.initStartVal = initStart; }

  getInitEnd(): number { return this.initEndVal; }
  setInitEnd(initEnd: number): void { this.initEndVal = initEnd; }

  getIndexStart(): number { return this.indexStartVal; }
  setIndexStart(indexStart: number): void { this.indexStartVal = indexStart; }

  getIndexEnd(): number { return this.indexEndVal; }
  setIndexEnd(indexEnd: number): void { this.indexEndVal = indexEnd; }

  getQuality(): string | undefined { return this.qualityVal; }
  setQuality(quality: string): void { this.qualityVal = quality; }

  getAudioQuality(): string | undefined { return this.audioQualityVal; }
  setAudioQuality(audioQuality: string): void { this.audioQualityVal = audioQuality; }

  getResolutionString(): string | undefined { return this.resolutionString; }

  getCodec(): string | undefined { return this.codecVal; }
  setCodec(codec: string): void { this.codecVal = codec; }

  getAverageBitrate(): number { return this.avgBitrate; }

  getSampleRate(): number { return this.sampleRateVal; }
  setSampleRate(sampleRate: number): void {
    this.sampleRateVal = sampleRate > 0 ? sampleRate : SAMPLE_RATE_UNKNOWN;
  }

  getAudioChannels(): number { return this.audioChannelsVal; }
  setAudioChannels(audioChannels: number): void {
    this.audioChannelsVal = audioChannels > 0 ? audioChannels : AUDIO_CHANNELS_NOT_APPLICABLE_OR_UNKNOWN;
  }

  getTargetDurationSec(): number { return this.targetDurationSecVal; }
  setTargetDurationSec(targetDurationSec: number): void {
    this.targetDurationSecVal = targetDurationSec > 0 ? targetDurationSec : TARGET_DURATION_SEC_UNKNOWN;
  }

  getApproxDurationMs(): number { return this.approxDurationMsVal; }
  setApproxDurationMs(approxDurationMs: number): void {
    this.approxDurationMsVal = approxDurationMs > 0 ? approxDurationMs : APPROX_DURATION_MS_UNKNOWN;
  }

  getContentLength(): number { return this.contentLengthVal; }
  setContentLength(contentLength: number): void {
    this.contentLengthVal = contentLength > 0 ? contentLength : CONTENT_LENGTH_UNKNOWN;
  }
}
