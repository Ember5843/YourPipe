import { AppLog } from './AppLog';
import {
  StreamInfo,
  muxAudioVideo,
  SabrOfflineDownloader,
  SabrOfflineProgress
} from 'mediaservice';
import common from '@ohos.app.ability.common';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { taskpool } from '@kit.ArkTS';
import { UIConfig } from './AppState';
import { formatBytes } from './utils/FormatUtils';
import { AuthSessionManager, HttpDownloader, parseHlsMasterManifest } from 'youtube_core';

const logger = AppLog.getInstance('DownloadManager');
const DOWNLOAD_ROOT: string = 'downloads';
const HTTP_CHUNK_SIZE: number = 10 * 1024 * 1024;
const DOWNLOAD_NOTIFICATION_TEMPLATE: string = 'downloadTemplate';
const DOWNLOAD_NOTIFICATION_MIN_INTERVAL_MS: number = 1200;
const DOWNLOAD_NOTIFICATION_MIN_PROGRESS_DELTA: number = 2;
const DOWNLOAD_NOTIFICATION_RATE_LIMIT_BACKOFF_MS: number = 5000;
const DOWNLOAD_NOTIFICATION_GLOBAL_INTERVAL_MS: number = 800;

@Concurrent
function muxTask(videoPath: string, audioPath: string, outPath: string): void {
  muxAudioVideo(videoPath, audioPath, outPath);
}

async function runMuxTask(videoPath: string, audioPath: string, outPath: string): Promise<void> {
  const task = new taskpool.Task(muxTask, videoPath, audioPath, outPath);
  await taskpool.execute(task);
}

export enum DownloadStatus {
  PENDING = 'pending',
  DOWNLOADING_VIDEO = 'downloading_video',
  DOWNLOADING_AUDIO = 'downloading_audio',
  MERGING = 'merging',
  COMPLETED = 'completed',
  FAILED = 'failed',
  CANCELLED = 'cancelled'
}

interface StreamChunkResult {
  responseCode: number;
  bytesWritten: number;
}

interface HlsMediaPlaylist {
  segments: string[];
  initUrl: string;
  isFmp4: boolean;
}

@Observed
export class DownloadTask {
  @Track id: string;
  @Track videoId: string;
  @Track title: string;
  @Track author: string;
  @Track thumbnailUrl: string;
  videoStream: StreamInfo;
  audioStream: StreamInfo | null;
  @Track status: DownloadStatus = DownloadStatus.PENDING;
  @Track progress: number = 0;
  @Track videoProgress: number = 0;
  @Track audioProgress: number = 0;
  @Track mergeProgress: number = 0;
  @Track totalSize: number = 0;
  @Track downloadedSize: number = 0;
  @Track videoDownloadedSize: number = 0;
  @Track audioDownloadedSize: number = 0;
  @Track errorMessage: string = '';
  @Track outputPath: string = '';
  @Track taskDir: string = '';
  @Track createdAt: number = Date.now();

  _cancelled: boolean = false;
  _videoFilePath: string = '';
  _audioFilePath: string = '';
  _context: common.UIAbilityContext | null = null;
  _notificationId: number = 0;
  _lastNotificationProgress: number = -1;
  _lastNotificationStatus: DownloadStatus = DownloadStatus.PENDING;
  _lastNotificationAt: number = 0;
  _notificationRateLimitedUntil: number = 0;

  constructor(
    id: string,
    videoId: string,
    title: string,
    author: string,
    thumbnailUrl: string,
    videoStream: StreamInfo,
    audioStream: StreamInfo | null
  ) {
    this.id = id;
    this.videoId = videoId;
    this.title = title;
    this.author = author;
    this.thumbnailUrl = thumbnailUrl;
    this.videoStream = videoStream;
    this.audioStream = audioStream;
    this.totalSize = (videoStream.contentLength || 0) + (audioStream?.contentLength || 0);
  }

  updateProgress(bytesDownloaded: number, total: number, type: 'video' | 'audio'): void {
    const pct = total > 0 ? Math.min(Math.round((bytesDownloaded / total) * 100), 100) : 0;

    if (type === 'video') {
      this.videoProgress = pct;
      this.videoDownloadedSize = bytesDownloaded;
    } else {
      this.audioProgress = pct;
      this.audioDownloadedSize = bytesDownloaded;
    }

    if (this.audioStream) {
      this.progress = Math.round(this.videoProgress * 0.7 + this.audioProgress * 0.25 + this.mergeProgress * 0.05);
    } else {
      this.progress = this.videoProgress;
    }

    this.downloadedSize = this.videoDownloadedSize + this.audioDownloadedSize;
  }

  updateMergeProgress(progress: number): void {
    this.mergeProgress = Math.max(0, Math.min(100, Math.round(progress)));
    if (this.audioStream) {
      this.progress = Math.round(this.videoProgress * 0.7 + this.audioProgress * 0.25 + this.mergeProgress * 0.05);
    }
  }

  getStatusLabel(): string {
    switch (this.status) {
      case DownloadStatus.PENDING: return 'Waiting';
      case DownloadStatus.DOWNLOADING_VIDEO: return 'Downloading video';
      case DownloadStatus.DOWNLOADING_AUDIO: return 'Downloading audio';
      case DownloadStatus.MERGING: return 'Merging';
      case DownloadStatus.COMPLETED: return 'Completed';
      case DownloadStatus.FAILED: return 'Failed';
      case DownloadStatus.CANCELLED: return 'Cancelled';
      default: return '';
    }
  }

  getFriendlySize(size: number): string {
    return formatBytes(size);
  }

  getProgressText(): string {
    if (this.totalSize > 0) {
      return `${this.getFriendlySize(this.downloadedSize)} / ${this.getFriendlySize(this.totalSize)}`;
    }
    return `${this.progress}%`;
  }
}

interface DownloadNotificationUpdate {
  task: DownloadTask;
  force: boolean;
  dueAt: number;
}

class DownloadNotificationDispatcher {
  private pendingUpdates: Map<string, DownloadNotificationUpdate> = new Map();
  private templateSupported: boolean | null = null;
  private templateSupportChecking: boolean = false;
  private disabled: boolean = false;
  private publishing: boolean = false;
  private flushTimer: number = -1;
  private lastGlobalPublishAt: number = 0;
  private nextNotificationId: number = 10000;
  private getStatusText: (task: DownloadTask) => string;
  private getFileName: (task: DownloadTask) => string;
  private truncateText: (value: string, maxLength: number) => string;

  constructor(
    getStatusText: (task: DownloadTask) => string,
    getFileName: (task: DownloadTask) => string,
    truncateText: (value: string, maxLength: number) => string
  ) {
    this.getStatusText = getStatusText;
    this.getFileName = getFileName;
    this.truncateText = truncateText;
  }

  enqueue(task: DownloadTask, force: boolean = false): void {
    if (task.status === DownloadStatus.PENDING || task.status === DownloadStatus.CANCELLED) {
      return;
    }
    if (this.disabled || this.templateSupported === false) {
      return;
    }

    const now = Date.now();
    const progress = this.clampProgress(task.progress);
    const dueAt = this.getTaskDueAt(task, progress, force, now);
    if (dueAt < 0) {
      return;
    }

    const current = this.pendingUpdates.get(task.id);
    this.pendingUpdates.set(task.id, {
      task,
      force: force || current?.force === true,
      dueAt: current ? Math.min(current.dueAt, dueAt) : dueAt
    });

    if (this.templateSupported === null) {
      this.checkTemplateSupport();
      return;
    }

    this.scheduleFlush(Math.max(0, dueAt - now));
  }

  cancel(task: DownloadTask): void {
    this.pendingUpdates.delete(task.id);
    if (task._notificationId === 0) {
      return;
    }
    notificationManager.cancel(task._notificationId, (err: BusinessError) => {
      if (err) {
        logger.warn(`Task ${task.id} progress notification cancel failed: code=${err.code}, message=${err.message}`);
      }
    });
  }

  private getTaskDueAt(task: DownloadTask, progress: number, force: boolean, now: number): number {
    if (now < task._notificationRateLimitedUntil && progress !== 100) {
      return task._notificationRateLimitedUntil;
    }

    const statusChanged = task._lastNotificationStatus !== task.status;
    const progressDelta = Math.abs(progress - task._lastNotificationProgress);
    const progressChangedEnough = task._lastNotificationProgress < 0 ||
      progressDelta >= DOWNLOAD_NOTIFICATION_MIN_PROGRESS_DELTA ||
      progress === 100;

    if (!force && !statusChanged && !progressChangedEnough) {
      return -1;
    }

    if (!force && !statusChanged) {
      return Math.max(now, task._lastNotificationAt + DOWNLOAD_NOTIFICATION_MIN_INTERVAL_MS);
    }

    return now;
  }

  private checkTemplateSupport(): void {
    if (this.templateSupportChecking) {
      return;
    }
    this.templateSupportChecking = true;
    notificationManager.isSupportTemplate(DOWNLOAD_NOTIFICATION_TEMPLATE).then((supported: boolean) => {
      this.templateSupported = supported;
      this.templateSupportChecking = false;
      logger.info(`Download notification template supported: ${supported}`);
      if (supported) {
        this.scheduleFlush(0);
      } else {
        this.pendingUpdates.clear();
      }
    }).catch((err: BusinessError) => {
      this.templateSupported = false;
      this.templateSupportChecking = false;
      this.pendingUpdates.clear();
      logger.warn(`Download notification template check failed: code=${err.code}, message=${err.message}`);
    });
  }

  private scheduleFlush(delayMs: number): void {
    if (this.flushTimer >= 0 || this.publishing || this.pendingUpdates.size === 0) {
      return;
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      this.flush();
    }, Math.max(0, delayMs));
  }

  private flush(): void {
    if (this.publishing || this.disabled || this.templateSupported !== true) {
      return;
    }
    if (this.pendingUpdates.size === 0) {
      return;
    }

    const now = Date.now();
    const globalDueAt = this.lastGlobalPublishAt + DOWNLOAD_NOTIFICATION_GLOBAL_INTERVAL_MS;
    if (now < globalDueAt) {
      this.scheduleFlush(globalDueAt - now);
      return;
    }

    const next = this.pickNextUpdate(now);
    if (!next) {
      this.scheduleFlush(this.getNextDueDelay(now));
      return;
    }

    this.pendingUpdates.delete(next.task.id);
    this.publish(next.task);
  }

  private pickNextUpdate(now: number): DownloadNotificationUpdate | null {
    let selected: DownloadNotificationUpdate | null = null;
    this.pendingUpdates.forEach((update: DownloadNotificationUpdate) => {
      if (update.dueAt > now) {
        return;
      }
      if (!selected || update.force || update.dueAt < selected.dueAt) {
        selected = update;
      }
    });
    return selected;
  }

  private getNextDueDelay(now: number): number {
    let nextDueAt = Number.MAX_SAFE_INTEGER;
    this.pendingUpdates.forEach((update: DownloadNotificationUpdate) => {
      nextDueAt = Math.min(nextDueAt, update.dueAt);
    });
    if (nextDueAt === Number.MAX_SAFE_INTEGER) {
      return DOWNLOAD_NOTIFICATION_GLOBAL_INTERVAL_MS;
    }
    return Math.max(0, nextDueAt - now);
  }

  private publish(task: DownloadTask): void {
    if (task._notificationId === 0) {
      task._notificationId = this.nextNotificationId++;
    }

    const progress = this.clampProgress(task.progress);
    const title = this.truncateText(task.title || task.videoId, 60);
    const statusText = this.getStatusText(task);
    const fileName = this.truncateText(this.getFileName(task), 80);
    const notificationRequest: notificationManager.NotificationRequest = {
      id: task._notificationId,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: statusText,
          additionalText: `${progress}%`
        }
      },
      template: {
        name: DOWNLOAD_NOTIFICATION_TEMPLATE,
        data: {
          title: title,
          fileName: fileName,
          progressValue: progress
        }
      }
    };

    this.publishing = true;
    this.lastGlobalPublishAt = Date.now();
    notificationManager.publish(notificationRequest, (err: BusinessError) => {
      this.publishing = false;
      if (err) {
        logger.warn(`Task ${task.id} progress notification publish failed: code=${err.code}, message=${err.message}`);
        if (err.code === 1600004 || (err.message && err.message.includes('Notification disabled'))) {
          this.disabled = true;
          this.pendingUpdates.clear();
        } else if (err.code === 1600009) {
          task._notificationRateLimitedUntil = Date.now() + DOWNLOAD_NOTIFICATION_RATE_LIMIT_BACKOFF_MS;
          this.enqueue(task, false);
        }
        this.scheduleFlush(DOWNLOAD_NOTIFICATION_GLOBAL_INTERVAL_MS);
        return;
      }

      task._lastNotificationProgress = progress;
      task._lastNotificationStatus = task.status;
      task._lastNotificationAt = Date.now();
      logger.debug(`Task ${task.id} progress notification published: progress=${progress} status=${task.status}`);
      this.scheduleFlush(0);
    });
  }

  private clampProgress(progress: number): number {
    return Math.max(0, Math.min(100, progress || 0));
  }
}

export class DownloadManager {
  private static instance: DownloadManager;
  private tasks: DownloadTask[] = [];
  private activeTaskIds: Set<string> = new Set();
  private exportTail: Promise<void> = Promise.resolve();
  private context: common.UIAbilityContext | null = null;
  private notificationDispatcher: DownloadNotificationDispatcher;

  private tr(resource: Resource, ...args: Array<string | number>): string {
    if (!this.context) {
      return '';
    }
    return this.context.resourceManager.getStringSync(resource.id, ...args);
  }

  private constructor() {
    this.notificationDispatcher = new DownloadNotificationDispatcher(
      (task: DownloadTask): string => this.getNotificationStatusText(task),
      (task: DownloadTask): string => this.getNotificationFileName(task),
      (value: string, maxLength: number): string => this.truncateNotificationText(value, maxLength)
    );
  }

  static getInstance(): DownloadManager {
    if (!DownloadManager.instance) {
      DownloadManager.instance = new DownloadManager();
    }
    return DownloadManager.instance;
  }

  getTasks(): DownloadTask[] {
    return this.tasks;
  }

  setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
    this.tasks.forEach((task: DownloadTask) => {
      if (!task._context) {
        task._context = ctx;
      }
    });
  }

  addTask(task: DownloadTask): void {
    if (!task._context && this.context) {
      task._context = this.context;
    }
    logger.info(`Task ${task.id} queued: video=${task.videoId} title="${task.title}" videoStream=${this.getStreamLogLabel(task.videoStream)} audioStream=${task.audioStream ? this.getStreamLogLabel(task.audioStream) : 'none'}`);
    this.tasks.unshift(task);
    this.notifyTasksChanged();
    this.processQueue();
  }

  cancelTask(taskId: string): void {
    const task = this.tasks.find((item: DownloadTask) => item.id === taskId);
    if (task && task.status !== DownloadStatus.COMPLETED) {
      task._cancelled = true;
      task.status = DownloadStatus.CANCELLED;
      logger.info(`Task ${task.id} cancelled`);
      this.cancelDownloadNotification(task);
      this.processQueue();
    }
  }

  deleteTask(taskId: string): void {
    const task = this.tasks.find((item: DownloadTask) => item.id === taskId);
    if (task) {
      task._cancelled = true;
      logger.info(`Task ${task.id} deleted includeOutput=true`);
      this.cancelDownloadNotification(task);
      this.cleanupTaskFiles(task, true);
    }
    this.tasks = this.tasks.filter((item: DownloadTask) => item.id !== taskId);
    this.notifyTasksChanged();
    this.processQueue();
  }

  async exportCompletedTask(taskId: string, destinationDir: string): Promise<string> {
    const task = this.tasks.find((item: DownloadTask) => item.id === taskId);
    if (!task) {
      throw new Error('Download task not found');
    }
    if (task.status !== DownloadStatus.COMPLETED || !task.outputPath) {
      throw new Error('Download task is not completed');
    }
    if (!destinationDir) {
      throw new Error('Missing destination directory');
    }

    let fileName = this.getFileName(task.outputPath);
    const dotIndex = fileName.lastIndexOf('.');
    const baseName = dotIndex >= 0 ? fileName.substring(0, dotIndex) : fileName;
    const ext = dotIndex >= 0 ? fileName.substring(dotIndex) : '';
    let counter = 1;
    let outputPath = `${destinationDir}/${fileName}`;
    while (fs.accessSync(outputPath)) {
      fileName = `${baseName}_${counter}${ext}`;
      outputPath = `${destinationDir}/${fileName}`;
      counter++;
    }
    fs.copyFileSync(task.outputPath, outputPath);
    logger.info(`Task ${task.id} exported to downloads: ${outputPath}`);
    this.deleteTask(task.id);
    return outputPath;
  }

  removeCompleted(): void {
    const retainedTasks = this.tasks.filter((task: DownloadTask) =>
      task.status === DownloadStatus.DOWNLOADING_VIDEO ||
      task.status === DownloadStatus.DOWNLOADING_AUDIO ||
      task.status === DownloadStatus.MERGING ||
      task.status === DownloadStatus.PENDING
    );
    this.tasks.forEach((task: DownloadTask) => {
      if (!retainedTasks.includes(task)) {
        this.cancelDownloadNotification(task);
      }
    });
    this.tasks = retainedTasks;
    this.notifyTasksChanged();
    this.processQueue();
  }

  refreshTaskPool(): void {
    this.processQueue();
  }

  private notifyTasksChanged(): void {
    AppStorage.setOrCreate('downloadTasks', [...this.tasks]);
  }

  private processQueue(): void {
    const maxActiveTasks = this.getMaxConcurrentDownloads();
    while (this.activeTaskIds.size < maxActiveTasks) {
      const pending = this.tasks.find((task: DownloadTask) => task.status === DownloadStatus.PENDING && !this.activeTaskIds.has(task.id));
      if (!pending) {
        return;
      }

      this.activeTaskIds.add(pending.id);
      logger.info(`Task ${pending.id} picked by taskpool: active=${this.activeTaskIds.size}/${maxActiveTasks}`);
      this.runTask(pending);
    }
  }

  private async runTask(task: DownloadTask): Promise<void> {
    try {
      await this.executeTask(task);
    } catch (error) {
      if (!task._cancelled) {
        task.status = DownloadStatus.FAILED;
        task.errorMessage = this.getErrorMessage(error);
        this.publishDownloadNotification(task, true);
      }
      logger.error(`Task ${task.id} failed: ${this.getErrorMessage(error)}`);
    } finally {
      this.activeTaskIds.delete(task.id);
      this.processQueue();
    }
  }

  private getMaxConcurrentDownloads(): number {
    const uiConfig = AppStorage.get<UIConfig>('uiConfig');
    const value = uiConfig?.maxConcurrentDownloads || 1;
    return Math.max(1, Math.min(4, Math.round(value)));
  }

  private isHlsStream(stream: StreamInfo): boolean {
    const kind = (stream.kind || '').toLowerCase();
    const delivery = (stream.deliveryMethod || '').toUpperCase();
    return kind === 'manifest_hls' || delivery === 'HLS';
  }

  private isSabrStream(stream: StreamInfo): boolean {
    return SabrOfflineDownloader.isSabrStream(stream);
  }

  /**
   * SABR offline: reuse playback SabrOfflineDownloader (UMP session + SabrTrackBuffer).
   * Requires sabrSessionStore HTTP/PO wiring from YouTubePlayService.initialize().
   */
  private async downloadSabrStreams(task: DownloadTask): Promise<void> {
    if (!task.audioStream) {
      task.status = DownloadStatus.FAILED;
      task.errorMessage = 'SABR download requires paired audio track';
      this.publishDownloadNotification(task, true);
      return;
    }
    if (!SabrOfflineDownloader.isSabrStream(task.videoStream)
      || !SabrOfflineDownloader.isSabrStream(task.audioStream)) {
      task.status = DownloadStatus.FAILED;
      task.errorMessage = 'SABR bootstrap missing (sabrInfo)';
      this.publishDownloadNotification(task, true);
      return;
    }

    task.taskDir = this.ensureTaskDir(task);
    // SABR UMP dumps are fragmented MP4/WebM (init + moof/mdat). Prefer container
    // from mime so FFmpeg remux sees a coherent track dump (PipePipe/yt-lab style).
    const videoExt = this.getSabrDumpExtension(task.videoStream);
    const audioExt = this.getSabrDumpExtension(task.audioStream);
    task._videoFilePath = `${task.taskDir}/video.${videoExt}`;
    task._audioFilePath = `${task.taskDir}/audio.${audioExt}`;
    logger.info(`Task ${task.id} SABR download start: video=${this.getStreamLogLabel(task.videoStream)} `
      + `audio=${this.getStreamLogLabel(task.audioStream)} dumpExt=v.${videoExt}/a.${audioExt}`);
    this.showToast(this.tr($r('app.string.yt_download_started_format'), this.truncateNotificationText(task.title || task.videoId, 36)));

    const videoFile = fs.openSync(task._videoFilePath,
      fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    const audioFile = fs.openSync(task._audioFilePath,
      fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    let videoFileOpen = true;
    let audioFileOpen = true;

    const writeTo = (file: fs.File, data: Uint8Array): void => {
      // Copy to a tight ArrayBuffer — writeSync expects ArrayBuffer, not a view offset.
      const copy = new ArrayBuffer(data.byteLength);
      new Uint8Array(copy).set(data);
      fs.writeSync(file.fd, copy);
    };

    try {
      task.status = DownloadStatus.DOWNLOADING_VIDEO;
      this.publishDownloadNotification(task, true);

      const durationMs = Math.max(
        task.videoStream.approxDurationMs || 0,
        task.audioStream.approxDurationMs || 0
      );
      const useAuth = AuthSessionManager.getInstance()?.isAuthEnabledForPlayback() === true;

      await SabrOfflineDownloader.downloadTracks({
        video: task.videoStream,
        audio: task.audioStream,
        durationMs: durationMs > 0 ? durationMs : undefined,
        useAuth: useAuth,
        isCancelled: (): boolean => task._cancelled,
        writeVideo: (data: Uint8Array): void => {
          writeTo(videoFile, data);
        },
        writeAudio: (data: Uint8Array): void => {
          writeTo(audioFile, data);
        },
        onProgress: (p: SabrOfflineProgress): void => {
          if (task._cancelled) {
            return;
          }
          const videoAdvanced = p.videoBytes > task.videoDownloadedSize;
          const audioAdvanced = p.audioBytes > task.audioDownloadedSize;
          if (videoAdvanced) {
            task.status = DownloadStatus.DOWNLOADING_VIDEO;
            const totalHint = task.videoStream.contentLength || 0;
            if (totalHint > 0) {
              task.updateProgress(p.videoBytes, totalHint, 'video');
            } else {
              task.videoProgress = p.percent;
              task.videoDownloadedSize = p.videoBytes;
            }
          }
          if (audioAdvanced) {
            task.status = DownloadStatus.DOWNLOADING_AUDIO;
            const totalHint = task.audioStream?.contentLength || 0;
            if (totalHint > 0) {
              task.updateProgress(p.audioBytes, totalHint, 'audio');
            } else {
              task.audioProgress = p.percent;
              task.audioDownloadedSize = p.audioBytes;
            }
          }
          task.downloadedSize = task.videoDownloadedSize + task.audioDownloadedSize;
          task.progress = Math.min(95, Math.round(
            task.videoProgress * 0.7 + task.audioProgress * 0.25));
          this.publishDownloadNotification(task);
        }
      });

      if (task._cancelled) {
        return;
      }

      // Match the DASH path: finish and close both independent track files
      // before FFmpeg opens them for muxing.
      fs.closeSync(videoFile);
      videoFileOpen = false;
      fs.closeSync(audioFile);
      audioFileOpen = false;

      task.status = DownloadStatus.MERGING;
      task.updateMergeProgress(5);
      logger.info(`Task ${task.id} SABR merging`);
      this.publishDownloadNotification(task, true);

      task.outputPath = await this.mergeOrCopy(task);
      task.status = DownloadStatus.COMPLETED;
      task.progress = 100;
      task.videoProgress = 100;
      task.audioProgress = 100;
      task.mergeProgress = 100;
      this.cleanupTaskFiles(task, false);
      logger.info(`Task ${task.id} SABR completed: output=${task.outputPath}`);
      this.publishDownloadNotification(task, true);
      const exportedPath = await this.runAutoExportAtTaskEnd(task);
      if (exportedPath) {
        this.showToast(this.tr($r('app.string.yt_download_saved_format'), this.truncateNotificationText(this.getFileName(exportedPath), 36)));
      } else {
        this.showToast(this.tr($r('app.string.yt_download_completed_format'), this.truncateNotificationText(task.title || task.videoId, 36)));
      }
    } catch (error) {
      if (task._cancelled || this.getErrorMessage(error) === 'cancelled') {
        task.status = DownloadStatus.CANCELLED;
        return;
      }
      task.status = DownloadStatus.FAILED;
      task.errorMessage = this.getErrorMessage(error);
      logger.error(`Task ${task.id} SABR failed: ${task.errorMessage}`);
      this.publishDownloadNotification(task, true);
    } finally {
      if (videoFileOpen) {
        try {
          fs.closeSync(videoFile);
        } catch (_e) {
        }
      }
      if (audioFileOpen) {
        try {
          fs.closeSync(audioFile);
        } catch (_e) {
        }
      }
    }
  }

  private async downloadHlsStream(task: DownloadTask): Promise<void> {
    logger.info(`Task ${task.id} HLS download start: stream=${this.getStreamLogLabel(task.videoStream)}`);
    task.status = DownloadStatus.DOWNLOADING_VIDEO;
    this.publishDownloadNotification(task, true);
    this.showToast(this.tr($r('app.string.yt_download_started_format'), this.truncateNotificationText(task.title || task.videoId, 36)));

    try {
      const manifestUrl = task.videoStream.url;
      if (!manifestUrl) {
        throw new Error('Missing HLS manifest URL');
      }

      // Master playlist → media playlist; never concat m3u8 text as media.
      const mediaPlaylistUrl = await this.resolveHlsMediaPlaylistUrl(manifestUrl);
      const playlist = await this.fetchHlsMediaPlaylist(mediaPlaylistUrl);
      if (playlist.segments.length === 0) {
        throw new Error('No segments found in HLS media playlist');
      }
      logger.info(`Task ${task.id} HLS: media=${mediaPlaylistUrl} segments=${playlist.segments.length} `
        + `init=${playlist.initUrl ? 'yes' : 'no'} fmp4=${playlist.isFmp4}`);

      task.taskDir = this.ensureTaskDir(task);
      // MPEG-TS segments are valid as .ts; fMP4 needs init+media and is not a plain .mp4 after concat.
      const safeTitle = this.sanitizeFilename(task.title || task.videoId);
      const outputExt = playlist.isFmp4 ? 'm4s' : 'ts';
      const outputPath = `${task.taskDir}/${safeTitle}.${outputExt}`;
      const outputFile = fs.openSync(outputPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);

      let totalDownloaded = 0;
      const writeParts: string[] = [];
      if (playlist.initUrl) {
        writeParts.push(playlist.initUrl);
      }
      for (let i = 0; i < playlist.segments.length; i++) {
        writeParts.push(playlist.segments[i]);
      }

      for (let i = 0; i < writeParts.length; i++) {
        if (task._cancelled) {
          fs.closeSync(outputFile);
          return;
        }
        const segData = await this.downloadHlsSegment(writeParts[i]);
        if (!segData || segData.byteLength === 0) {
          fs.closeSync(outputFile);
          throw new Error(`Empty HLS part ${i + 1}/${writeParts.length}`);
        }
        // Guard against accidentally writing another playlist as a "segment".
        if (this.looksLikeHlsPlaylist(segData)) {
          fs.closeSync(outputFile);
          throw new Error('HLS part is still a playlist text; media playlist resolution failed');
        }
        totalDownloaded += segData.byteLength;
        fs.writeSync(outputFile.fd, segData);
        const pct = Math.round(((i + 1) / writeParts.length) * 100);
        task.videoProgress = pct;
        task.progress = pct;
        task.downloadedSize = totalDownloaded;
        this.publishDownloadNotification(task);
        logger.debug(`Task ${task.id} HLS: part ${i + 1}/${writeParts.length} done bytes=${segData.byteLength}`);
      }

      fs.closeSync(outputFile);

      // fMP4 concat without container rebuild is not a proper MP4; fail clearly rather than ship garbage.
      if (playlist.isFmp4) {
        this.safeUnlink(outputPath);
        throw new Error('HLS fMP4 (CMAF) offline remux is not supported yet; pick Progressive or DASH');
      }

      task.outputPath = outputPath;
      task.status = DownloadStatus.COMPLETED;
      task.progress = 100;
      task.videoProgress = 100;
      logger.info(`Task ${task.id} HLS completed: output=${outputPath} bytes=${totalDownloaded}`);
      this.publishDownloadNotification(task, true);
      this.showToast(this.tr($r('app.string.yt_download_completed_format'), this.truncateNotificationText(task.title || task.videoId, 36)));
    } catch (error) {
      if (task._cancelled) {
        task.status = DownloadStatus.CANCELLED;
        return;
      }
      task.status = DownloadStatus.FAILED;
      task.errorMessage = this.getErrorMessage(error);
      logger.error(`Task ${task.id} HLS failed: ${task.errorMessage}`);
      this.publishDownloadNotification(task, true);
    }
  }

  private async resolveHlsMediaPlaylistUrl(manifestUrl: string): Promise<string> {
    const text = await this.fetchHlsText(manifestUrl);
    if (!text) {
      throw new Error('Empty HLS manifest');
    }
    if (!this.isHlsMasterPlaylist(text)) {
      return manifestUrl;
    }
    // Master 解析统一走 youtube_core HlsManifestParser（不含 BANDWIDTH，按高度选最高清晰度）。
    const variants = parseHlsMasterManifest(text, '')
      .videoStreams.filter((s) => !!s.url);
    if (variants.length === 0) {
      throw new Error('HLS master playlist has no variants');
    }
    variants.sort((a, b) => (b.height || 0) - (a.height || 0));
    logger.info(`HLS master: picked height=${variants[0].height || 0} url=${variants[0].url}`);
    return variants[0].url;
  }

  private async fetchHlsMediaPlaylist(mediaPlaylistUrl: string): Promise<HlsMediaPlaylist> {
    const text = await this.fetchHlsText(mediaPlaylistUrl);
    if (!text) {
      throw new Error('Empty HLS media playlist');
    }
    if (this.isHlsMasterPlaylist(text)) {
      throw new Error('Expected media playlist but got master playlist');
    }
    return this.parseHlsMediaPlaylist(text, mediaPlaylistUrl);
  }

  private async fetchHlsText(url: string): Promise<string> {
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        header: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36',
          'Referer': 'https://www.youtube.com/',
        },
        connectTimeout: 15000,
        readTimeout: 15000,
      };
      HttpDownloader.applyProxyToOptions(options, url);
      const response = await request.request(url, options);
      return typeof response.result === 'string' ? response.result : '';
    } finally {
      request.destroy();
    }
  }

  private isHlsMasterPlaylist(text: string): boolean {
    return text.indexOf('#EXT-X-STREAM-INF') >= 0;
  }

  private parseHlsMediaPlaylist(manifestText: string, baseUrl: string): HlsMediaPlaylist {
    const lines = manifestText.split(/\r?\n/);
    const segments: string[] = [];
    let initUrl: string = '';
    let isFmp4 = false;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line) {
        continue;
      }
      if (line.startsWith('#EXT-X-MAP:')) {
        const uriMatch = line.match(/URI="([^"]+)"/i);
        if (uriMatch && uriMatch[1]) {
          initUrl = this.resolveHlsUrl(uriMatch[1], baseUrl);
          isFmp4 = true;
        }
        continue;
      }
      if (line.startsWith('#')) {
        continue;
      }
      segments.push(this.resolveHlsUrl(line, baseUrl));
    }
    // Heuristic: .m4s / .mp4 segment names without MAP still imply fMP4.
    if (!isFmp4 && segments.length > 0) {
      const sample = segments[0].toLowerCase();
      if (sample.indexOf('.m4s') >= 0 || sample.indexOf('mime=video%2fmp4') >= 0 || sample.indexOf('mime=video/mp4') >= 0) {
        isFmp4 = true;
      }
    }
    return { segments: segments, initUrl: initUrl, isFmp4: isFmp4 };
  }

  private resolveHlsUrl(ref: string, baseUrl: string): string {
    if (ref.startsWith('http://') || ref.startsWith('https://')) {
      return ref;
    }
    try {
      // Absolute path on same origin.
      if (ref.startsWith('/')) {
        const schemeEnd = baseUrl.indexOf('://');
        if (schemeEnd > 0) {
          const pathStart = baseUrl.indexOf('/', schemeEnd + 3);
          const origin = pathStart > 0 ? baseUrl.substring(0, pathStart) : baseUrl;
          return origin + ref;
        }
      }
    } catch (_e) {
    }
    const slash = baseUrl.lastIndexOf('/');
    const base = slash >= 0 ? baseUrl.substring(0, slash + 1) : '';
    return base + ref;
  }

  private looksLikeHlsPlaylist(data: ArrayBuffer): boolean {
    if (data.byteLength < 8 || data.byteLength > 512 * 1024) {
      return false;
    }
    try {
      const bytes = new Uint8Array(data);
      // #EXTM3U
      return bytes[0] === 0x23 && bytes[1] === 0x45 && bytes[2] === 0x58 && bytes[3] === 0x54;
    } catch (_e) {
      return false;
    }
  }

  private async downloadHlsSegment(url: string): Promise<ArrayBuffer> {
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36',
          'Referer': 'https://www.youtube.com/',
        },
        connectTimeout: 15000,
        readTimeout: 60000,
      };
      HttpDownloader.applyProxyToOptions(options, url);
      const response = await request.request(url, options);
      if (response.responseCode !== 200 && response.responseCode !== 206) {
        throw new Error(`HLS segment HTTP ${response.responseCode}`);
      }
      return response.result as ArrayBuffer;
    } finally {
      request.destroy();
    }
  }

  private async executeTask(task: DownloadTask): Promise<void> {
    if (task._cancelled) {
      return;
    }
    if (!task._context) {
      task.status = DownloadStatus.FAILED;
      task.errorMessage = 'Missing app context';
      return;
    }

    if (this.isHlsStream(task.videoStream)) {
      await this.downloadHlsStream(task);
      return;
    }

    if (this.isSabrStream(task.videoStream)) {
      await this.downloadSabrStreams(task);
      return;
    }

    task.taskDir = this.ensureTaskDir(task);
    const videoExt = this.getFileExtension(task.videoStream);
    const audioExt = task.audioStream ? this.getFileExtension(task.audioStream) : '';
    task._videoFilePath = `${task.taskDir}/video.${videoExt}`;
    task._audioFilePath = task.audioStream ? `${task.taskDir}/audio.${audioExt}` : '';
    logger.info(`Task ${task.id} start: dir=${task.taskDir} totalSize=${task.totalSize || 'unknown'} video=${this.getStreamLogLabel(task.videoStream)} audio=${task.audioStream ? this.getStreamLogLabel(task.audioStream) : 'none'}`);
    this.showToast(this.tr($r('app.string.yt_download_started_format'), this.truncateNotificationText(task.title || task.videoId, 36)));

    task.status = DownloadStatus.DOWNLOADING_VIDEO;
    this.publishDownloadNotification(task, true);
    await this.downloadStream(task, task.videoStream, task._videoFilePath, 'video');
    if (task._cancelled) {
      return;
    }

    if (task.audioStream) {
      task.status = DownloadStatus.DOWNLOADING_AUDIO;
      this.publishDownloadNotification(task, true);
      await this.downloadStream(task, task.audioStream, task._audioFilePath, 'audio');
      if (task._cancelled) {
        return;
      }
    }

    task.status = DownloadStatus.MERGING;
    task.updateMergeProgress(5);
    logger.info(`Task ${task.id} merging`);
    this.publishDownloadNotification(task, true);

    task.outputPath = await this.mergeOrCopy(task);
    task.status = DownloadStatus.COMPLETED;
    task.progress = 100;
    task.videoProgress = 100;
    task.audioProgress = task.audioStream ? 100 : 0;
    task.mergeProgress = 100;
    this.cleanupTaskFiles(task, false);
    logger.info(`Task ${task.id} completed: output=${task.outputPath}`);
    this.publishDownloadNotification(task, true);
    const exportedPath = await this.runAutoExportAtTaskEnd(task);
    if (exportedPath) {
      this.showToast(this.tr($r('app.string.yt_download_saved_format'), this.truncateNotificationText(this.getFileName(exportedPath), 36)));
    } else {
      this.showToast(this.tr($r('app.string.yt_download_completed_format'), this.truncateNotificationText(task.title || task.videoId, 36)));
    }
  }

  private async runAutoExportAtTaskEnd(task: DownloadTask): Promise<string | null> {
    const previousExport = this.exportTail;
    let releaseExport: () => void = () => {};
    this.exportTail = new Promise<void>((resolve: () => void) => {
      releaseExport = resolve;
    });

    await previousExport;
    try {
      return await this.autoExportCompletedTask(task);
    } finally {
      releaseExport();
    }
  }

  private async autoExportCompletedTask(task: DownloadTask): Promise<string | null> {
    if (!this.tasks.includes(task) || !task._context || task.status !== DownloadStatus.COMPLETED || !task.outputPath) {
      return null;
    }

    try {
      logger.info(`Task ${task.id} auto export prompt opening`);
      const documentViewPicker = new picker.DocumentViewPicker(task._context);
      const documentSaveOptions = new picker.DocumentSaveOptions();
      documentSaveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const result = await documentViewPicker.save(documentSaveOptions);
      if (!result || result.length === 0) {
        logger.info(`Task ${task.id} auto export cancelled`);
        return null;
      }

      const destinationDir = new fileUri.FileUri(result[0]).path;
      const exportedPath = await this.exportCompletedTask(task.id, destinationDir);
      logger.info(`Task ${task.id} auto export completed: ${exportedPath}`);
      return exportedPath;
    } catch (error) {
      logger.warn(`Task ${task.id} auto export failed: ${this.getErrorMessage(error)}`);
      return null;
    }
  }

  private async downloadStream(
    task: DownloadTask,
    stream: StreamInfo,
    filePath: string,
    type: 'video' | 'audio'
  ): Promise<void> {
    const totalBytes = stream.contentLength || 0;
    const chunkCount = totalBytes > 0 ? Math.ceil(totalBytes / HTTP_CHUNK_SIZE) : 1;
    logger.info(`Task ${task.id} ${type} download start: mode=${totalBytes > 0 ? 'chunked-stream' : 'stream'} chunks=${chunkCount} chunkSize=${HTTP_CHUNK_SIZE} size=${totalBytes || 'unknown'} stream=${this.getStreamLogLabel(stream)}`);

    if (!stream.url || stream.url.length === 0) {
      throw new Error(`Missing ${type} stream URL`);
    }

    const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      if (totalBytes > 0) {
        await this.downloadChunkedStream(task, stream, file, type, totalBytes);
      } else {
        await this.downloadUnknownSizeStream(task, stream, file, type);
      }
    } finally {
      fs.closeSync(file);
    }

    if (task._cancelled) {
      return;
    }

    const actualSize = this.getLocalFileSize(filePath);
    const expected = type === 'video' ? task.videoDownloadedSize : task.audioDownloadedSize;
    if (actualSize <= 0) {
      throw new Error(`${type} file is empty after download`);
    }
    if (totalBytes > 0 && actualSize !== totalBytes) {
      throw new Error(`${type} size mismatch file=${actualSize} expected=${totalBytes}`);
    }
    if (expected > 0 && actualSize !== expected) {
      logger.warn(`Task ${task.id} ${type} size note: file=${actualSize} tracked=${expected}`);
    }
    // Reject tiny stubs (often HTML/error bodies mislabeled as media).
    if (actualSize < 1024) {
      throw new Error(`${type} download too small (${actualSize} B); likely not media`);
    }

    logger.info(`Task ${task.id} ${type} stream download completed: ${filePath} bytes=${actualSize}`);
  }

  private getLocalFileSize(path: string): number {
    try {
      if (!path || !fs.accessSync(path)) {
        return 0;
      }
      const st = fs.statSync(path);
      return st.size || 0;
    } catch (_e) {
      return 0;
    }
  }

  private async downloadChunkedStream(
    task: DownloadTask,
    stream: StreamInfo,
    file: fs.File,
    type: 'video' | 'audio',
    totalBytes: number
  ): Promise<void> {
    let downloaded = 0;
    let chunkIndex = 0;
    while (downloaded < totalBytes) {
      if (task._cancelled) {
        return;
      }

      const start = downloaded;
      const end = Math.min(start + HTTP_CHUNK_SIZE - 1, totalBytes - 1);
      const expectedSize = end - start + 1;
      const rangeSpec = `${start}-${end}`;
      chunkIndex++;
      logger.debug(`Task ${task.id} ${type} chunk ${chunkIndex}: range=${rangeSpec}`);

      const result = await this.requestStreamToFile(
        this.buildStreamUrl(stream.url, rangeSpec),
        this.buildStreamHeaders(stream.url, rangeSpec),
        file,
        task,
        (chunkWritten: number) => {
          task.updateProgress(start + chunkWritten, totalBytes, type);
          this.publishDownloadNotification(task);
        }
      );

      if (task._cancelled) {
        return;
      }
      if (result.responseCode !== 206 && result.responseCode !== 200) {
        throw new Error(`Chunk request returned HTTP ${result.responseCode}`);
      }
      if (result.bytesWritten !== expectedSize) {
        throw new Error(`Chunk size mismatch expected=${expectedSize} actual=${result.bytesWritten}`);
      }
      downloaded += result.bytesWritten;
      task.updateProgress(downloaded, totalBytes, type);
      this.publishDownloadNotification(task);
    }
  }

  private async downloadUnknownSizeStream(
    task: DownloadTask,
    stream: StreamInfo,
    file: fs.File,
    type: 'video' | 'audio'
  ): Promise<void> {
    const result = await this.requestStreamToFile(
      stream.url,
      { 'Accept-Encoding': 'identity' },
      file,
      task,
      (written: number) => {
        task.updateProgress(written, written, type);
        this.publishDownloadNotification(task);
      }
    );
    if (task._cancelled) {
      return;
    }
    if (result.responseCode !== 200 && result.responseCode !== 206) {
      throw new Error(`HTTP ${result.responseCode}`);
    }
    task.updateProgress(result.bytesWritten, result.bytesWritten, type);
    this.publishDownloadNotification(task);
  }

  private async requestStreamToFile(
    url: string,
    header: Record<string, string>,
    file: fs.File,
    task: DownloadTask,
    onProgress: (written: number) => void,
    redirectDepth: number = 0
  ): Promise<StreamChunkResult> {
    if (redirectDepth > 5) {
      throw new Error('Too many redirects');
    }
    const httpRequest = http.createHttp();
    return new Promise<StreamChunkResult>((resolve, reject) => {
      let bytesWritten = 0;
      let responseCode = 0;
      let requestReturned = false;
      let streamEnded = false;
      let settled = false;
      let redirectLocation: string | null = null;

      const cleanup = (): void => {
        try {
          httpRequest.off('headersReceive');
          httpRequest.off('dataReceive');
          httpRequest.off('dataEnd');
        } catch (_error) {
        }
      };

      const finishResolve = (result: StreamChunkResult): void => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        try {
          httpRequest.destroy();
        } catch (_error) {
        }
        resolve(result);
      };

      const finishReject = (error: Error | Object): void => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        try {
          httpRequest.destroy();
        } catch (_error) {
        }
        reject(error);
      };

      const followRedirect = (): void => {
        if (settled || !redirectLocation) {
          return;
        }
        settled = true;
        cleanup();
        try {
          httpRequest.destroy();
        } catch (_error) {
        }
        this.requestStreamToFile(redirectLocation, header, file, task, onProgress, redirectDepth + 1)
          .then(resolve)
          .catch(reject);
      };

      const tryFinish = (): void => {
        if (settled || !requestReturned) {
          return;
        }
        if (responseCode >= 300 && responseCode < 400) {
          if (redirectLocation) {
            followRedirect();
            return;
          }
          finishReject(new Error(`HTTP redirect ${responseCode} without Location`));
          return;
        }
        if (streamEnded) {
          finishResolve({ responseCode: responseCode, bytesWritten: bytesWritten });
        }
      };

      httpRequest.on('headersReceive', (headers: Object) => {
        redirectLocation = this.getRedirectLocation(headers as Record<string, string | string[]>);
      });

      httpRequest.on('dataReceive', (data: ArrayBuffer) => {
        if (task._cancelled) {
          finishResolve({ responseCode: responseCode, bytesWritten: bytesWritten });
          return;
        }
        try {
          if (data.byteLength > 0) {
            fs.writeSync(file.fd, data);
            bytesWritten += data.byteLength;
            onProgress(bytesWritten);
          }
        } catch (error) {
          finishReject(error as Error);
        }
      });

      httpRequest.on('dataEnd', () => {
        streamEnded = true;
        tryFinish();
      });

      const streamOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header,
        connectTimeout: 30000,
        readTimeout: 120000,
        usingCache: false
      };
      HttpDownloader.applyProxyToOptions(streamOptions, url);
      httpRequest.requestInStream(
        url,
        streamOptions
      ).then((code: number) => {
        responseCode = code || 0;
        requestReturned = true;
        tryFinish();
      }).catch((error: Error) => {
        finishReject(error);
      });
    });
  }

  private buildStreamHeaders(url: string, rangeSpec: string): Record<string, string> {
    const header: Record<string, string> = { 'Accept-Encoding': 'identity' };
    if (!this.isYoutubePlaybackUrl(url)) {
      header['Range'] = `bytes=${rangeSpec}`;
    }
    return header;
  }

  private buildStreamUrl(url: string, rangeSpec: string): string {
    if (!this.isYoutubePlaybackUrl(url)) {
      return url;
    }
    return this.buildRangeUrl(url, rangeSpec);
  }

  private getRedirectLocation(headers: Record<string, string | string[] | Object>): string | null {
    const keys = ['Location', 'location'];
    for (const key of keys) {
      const value = headers[key];
      if (typeof value === 'string' && value.length > 0) {
        return value;
      }
      if (Array.isArray(value) && value.length > 0 && typeof value[0] === 'string' && value[0]) {
        return value[0];
      }
    }
    return null;
  }

  private publishDownloadNotification(task: DownloadTask, force: boolean = false): void {
    this.notificationDispatcher.enqueue(task, force);
  }

  private cancelDownloadNotification(task: DownloadTask): void {
    this.notificationDispatcher.cancel(task);
  }

  private getNotificationStatusText(task: DownloadTask): string {
    if (task.status === DownloadStatus.FAILED) {
      return task.errorMessage || this.tr($r('app.string.yt_download_status_failed'));
    }
    const progressText = task.getProgressText();
    return progressText ? `${task.getStatusLabel()} · ${progressText}` : task.getStatusLabel();
  }

  private getNotificationFileName(task: DownloadTask): string {
    if (task.outputPath) {
      return this.getFileName(task.outputPath);
    }
    const safeTitle = this.sanitizeFilename(task.title || task.videoId);
    return `${safeTitle}.${this.getOutputExtension(task)}`;
  }

  private truncateNotificationText(value: string, maxLength: number): string {
    if (value.length <= maxLength) {
      return value;
    }
    return `${value.substring(0, Math.max(0, maxLength - 3))}...`;
  }

  private showToast(message: string): void {
    try {
      const uiContext = AppStorage.get<UIContext>('uiContext');
      if (!uiContext) {
        logger.warn(`Download toast skipped, missing uiContext: ${message}`);
        return;
      }
      uiContext.getPromptAction().showToast({
        message,
        duration: 2000
      });
      logger.debug(`Download toast requested: ${message}`);
    } catch (error) {
      logger.warn(`Download toast failed: ${this.getErrorMessage(error)}`);
    }
  }

  private async mergeOrCopy(task: DownloadTask): Promise<string> {
    const safeTitle = this.sanitizeFilename(task.title || task.videoId);
    const outputExt = this.getOutputExtension(task);
    const outputPath = `${task.taskDir}/${safeTitle}.${outputExt}`;

    const videoSize = this.getLocalFileSize(task._videoFilePath);
    if (videoSize <= 0) {
      throw new Error('Video track missing before merge');
    }

    if (task.audioStream && task._audioFilePath) {
      const audioSize = this.getLocalFileSize(task._audioFilePath);
      if (audioSize <= 0) {
        throw new Error('Audio track missing before merge');
      }
      logger.info(`Task ${task.id} mux merge output=${outputExt} videoExt=${this.getFileExtension(task.videoStream)} audioExt=${this.getFileExtension(task.audioStream)} videoBytes=${videoSize} audioBytes=${audioSize}`);

      const videoPath = task._videoFilePath;
      const audioPath = task._audioFilePath;
      const outPath = outputPath;

      try {
        // Remove stale incomplete output from a previous failed mux attempt.
        this.safeUnlink(outPath);
        await runMuxTask(videoPath, audioPath, outPath);
      } catch (e) {
        this.safeUnlink(outPath);
        const msg = (e as Error).message || String(e);
        logger.error(`Task ${task.id} mux failed: ${msg}`);
        throw new Error(`合并失败: ${msg}`);
      }

      const outSize = this.getLocalFileSize(outPath);
      if (outSize <= 0) {
        this.safeUnlink(outPath);
        throw new Error('Mux produced empty output');
      }
      // Output should at least cover the larger track plus container overhead.
      if (outSize < Math.max(videoSize, audioSize) * 0.5) {
        this.safeUnlink(outPath);
        throw new Error(`Mux output too small (${outSize} B vs video=${videoSize} audio=${audioSize})`);
      }

      task.updateMergeProgress(100);
      this.publishDownloadNotification(task);
    } else {
      fs.copyFileSync(task._videoFilePath, outputPath);
      task.updateMergeProgress(100);
      this.publishDownloadNotification(task);
    }

    logger.info(`File saved to app downloads: ${outputPath} bytes=${this.getLocalFileSize(outputPath)}`);
    return outputPath;
  }

  private getStreamLogLabel(stream: StreamInfo): string {
    const parts: string[] = [];
    if (stream.itag) parts.push(`itag=${stream.itag}`);
    if (stream.kind) parts.push(`kind=${stream.kind}`);
    if (stream.quality || stream.videoQuality || stream.audioQuality) {
      parts.push(`quality=${stream.quality || stream.videoQuality || stream.audioQuality}`);
    }
    if (stream.mimeType) parts.push(`mime=${stream.mimeType.split(';')[0]}`);
    if (stream.codecs) parts.push(`codecs=${stream.codecs}`);
    if (stream.bitrate) parts.push(`bitrate=${stream.bitrate}`);
    if (stream.contentLength) parts.push(`size=${stream.contentLength}`);
    return parts.length > 0 ? parts.join(',') : 'unknown';
  }

  private ensureTaskDir(task: DownloadTask): string {
    if (!task._context) {
      throw new Error('Missing app context');
    }
    const root = `${task._context.filesDir}/${DOWNLOAD_ROOT}`;
    const taskDir = `${root}/${task.id}`;
    this.ensureDir(root);
    this.ensureDir(taskDir);
    return taskDir;
  }

  private ensureDir(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path, true);
      }
    } catch (_error) {
      fs.mkdirSync(path, true);
    }
  }

  private cleanupTaskFiles(task: DownloadTask, includeOutput: boolean): void {
    [task._videoFilePath, task._audioFilePath].forEach((path: string) => this.safeUnlink(path));
    this.safeRemoveDir(`${task.taskDir}/video_parts`);
    this.safeRemoveDir(`${task.taskDir}/audio_parts`);
    if (includeOutput && task.taskDir) {
      this.safeRemoveDir(task.taskDir);
    }
  }

  private safeUnlink(path: string): void {
    if (!path) {
      return;
    }
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (_error) {
    }
  }

  private safeRemoveDir(path: string): void {
    if (!path) {
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      const files = fs.listFileSync(path);
      files.forEach((name: string) => {
        const child = `${path}/${name}`;
        try {
          this.safeUnlink(child);
        } catch (_error) {
          this.safeRemoveDir(child);
        }
      });
      fs.rmdirSync(path);
    } catch (_error) {
    }
  }

  private buildRangeUrl(url: string, rangeSpec: string): string {
    if (!this.isYoutubePlaybackUrl(url)) {
      return url;
    }
    const separator = url.includes('?') ? '&' : '?';
    return `${url}${separator}range=${rangeSpec}`;
  }

  private isYoutubePlaybackUrl(url: string): boolean {
    const lower = url.toLowerCase();
    return lower.includes('googlevideo.com') || lower.includes('youtube.com') || lower.includes('youtu.be');
  }

  private getOutputExtension(task: DownloadTask): string {
    const videoExt = this.getFileExtension(task.videoStream);
    const audioExt = task.audioStream ? this.getFileExtension(task.audioStream) : '';
    if (!task.audioStream || videoExt === audioExt) {
      return videoExt;
    }

    const videoMime = (task.videoStream.mimeType || '').toLowerCase();
    const audioMime = (task.audioStream.mimeType || '').toLowerCase();
    const videoCodecs = (task.videoStream.codecs || '').toLowerCase();
    const audioCodecs = (task.audioStream.codecs || '').toLowerCase();
    const isMp4Video = videoExt === 'mp4' || videoMime.includes('mp4') ||
      videoCodecs.includes('avc1') || videoCodecs.includes('avc3') ||
      videoCodecs.includes('hvc1') || videoCodecs.includes('hev1');
    const isWebmAudio = audioExt === 'webm' || audioExt === 'opus' || audioMime.includes('webm') ||
      audioCodecs.includes('opus') || audioCodecs.includes('vp9') || audioCodecs.includes('vp09');

    if (isMp4Video && isWebmAudio) {
      return 'mkv';
    }

    const isMp4Audio = audioExt === 'mp4' || audioExt === 'm4a' || audioExt === 'aac' ||
      audioMime.includes('mp4') || audioCodecs.includes('mp4a');
    const isWebmVideo = videoExt === 'webm' || videoMime.includes('webm') ||
      videoCodecs.includes('vp9') || videoCodecs.includes('vp09') || videoCodecs.includes('av01');
    if (isWebmVideo && isMp4Audio) {
      return 'mkv';
    }

    if (isMp4Video && isMp4Audio) {
      return 'mp4';
    }
    if (isWebmVideo && isWebmAudio) {
      return 'webm';
    }

    return 'mkv';
  }

  private getFileExtension(stream: StreamInfo): string {
    const mime = (stream.mimeType || '').toLowerCase();
    if (mime.includes('webm')) return 'webm';
    if (mime.includes('3gpp')) return '3gp';
    if (mime.includes('mp4')) return 'mp4';
    if (mime.includes('mpeg') && !stream.videoQuality) return 'mp3';
    if (mime.includes('aac')) return 'aac';
    if (mime.includes('ogg') || mime.includes('opus')) return 'opus';
    const kind = (stream.kind || '').toLowerCase();
    if (kind.includes('audio')) return 'm4a';
    return 'mp4';
  }

  /** Intermediate SABR track dump extension (fMP4/WebM fragments). */
  private getSabrDumpExtension(stream: StreamInfo): string {
    const mime = (stream.mimeType || '').toLowerCase();
    const codecs = (stream.codecs || '').toLowerCase();
    if (mime.includes('webm') || codecs.includes('vp9') || codecs.includes('vp09')
      || codecs.includes('av01') || codecs.includes('opus')) {
      return 'webm';
    }
    // audio/mp4 → m4a is fine for a pure audio dump before mux
    if (mime.includes('audio') && mime.includes('mp4')) {
      return 'm4a';
    }
    return 'mp4';
  }

  private sanitizeFilename(name: string): string {
    const value = name.replace(/[\\/:*?"<>|]/g, '_')
      .replace(/\s+/g, '_')
      .substring(0, 80)
      .trim();
    return value.length > 0 ? value : 'download';
  }

  private getFileName(path: string): string {
    const index = path.lastIndexOf('/');
    return index >= 0 ? path.substring(index + 1) : path;
  }

  private getErrorMessage(error: Object | string | undefined): string {
    if (!error) {
      return 'Unknown error';
    }
    if (typeof error === 'string') {
      return error;
    }
    const maybeError = error as Error;
    return maybeError.message || JSON.stringify(error);
  }
}
