import { AppLog } from './AppLog';
import { StreamInfo } from 'mediaservice';
import common from '@ohos.app.ability.common';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { FFmpeg } from '@sj/ffmpeg';

const logger = AppLog.getInstance('DownloadManager');
const DOWNLOAD_ROOT: string = 'downloads';
const DEFAULT_THREAD_COUNT: number = 4;
const MIN_THREAD_COUNT: number = 1;
const MAX_THREAD_COUNT: number = 8;
const WRITE_CHUNK_SIZE: number = 256 * 1024;

export enum DownloadStatus {
  PENDING = 'pending',
  DOWNLOADING_VIDEO = 'downloading_video',
  DOWNLOADING_AUDIO = 'downloading_audio',
  MERGING = 'merging',
  COMPLETED = 'completed',
  FAILED = 'failed',
  CANCELLED = 'cancelled'
}

interface RangePart {
  index: number;
  start: number;
  end: number;
  filePath: string;
}

interface PartProgress {
  total: number;
  parts: number[];
}

@Observed
export class DownloadTask {
  id: string;
  videoId: string;
  title: string;
  author: string;
  thumbnailUrl: string;
  videoStream: StreamInfo;
  audioStream: StreamInfo | null;
  threadCount: number = DEFAULT_THREAD_COUNT;
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
  createdAt: number = Date.now();

  _cancelled: boolean = false;
  _videoFilePath: string = '';
  _audioFilePath: string = '';
  _context: common.UIAbilityContext | null = null;

  constructor(
    id: string,
    videoId: string,
    title: string,
    author: string,
    thumbnailUrl: string,
    videoStream: StreamInfo,
    audioStream: StreamInfo | null,
    threadCount: number = DEFAULT_THREAD_COUNT
  ) {
    this.id = id;
    this.videoId = videoId;
    this.title = title;
    this.author = author;
    this.thumbnailUrl = thumbnailUrl;
    this.videoStream = videoStream;
    this.audioStream = audioStream;
    this.threadCount = Math.max(MIN_THREAD_COUNT, Math.min(MAX_THREAD_COUNT, Math.round(threadCount)));
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
    if (size <= 0) return '';
    if (size < 1024) return `${size} B`;
    if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
    if (size < 1024 * 1024 * 1024) return `${(size / (1024 * 1024)).toFixed(1)} MB`;
    return `${(size / (1024 * 1024 * 1024)).toFixed(2)} GB`;
  }

  getProgressText(): string {
    if (this.totalSize > 0) {
      return `${this.getFriendlySize(this.downloadedSize)} / ${this.getFriendlySize(this.totalSize)}`;
    }
    return `${this.progress}%`;
  }
}

export class DownloadManager {
  private static instance: DownloadManager;
  private tasks: DownloadTask[] = [];
  private activeTaskId: string | null = null;
  private context: common.UIAbilityContext | null = null;

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
    logger.info(`Task ${task.id} queued: video=${task.videoId} title="${task.title}" threads=${task.threadCount} videoStream=${this.getStreamLogLabel(task.videoStream)} audioStream=${task.audioStream ? this.getStreamLogLabel(task.audioStream) : 'none'}`);
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
      this.notifyTasksChanged();
    }
  }

  deleteTask(taskId: string): void {
    const task = this.tasks.find((item: DownloadTask) => item.id === taskId);
    if (task) {
      task._cancelled = true;
      logger.info(`Task ${task.id} deleted includeOutput=true`);
      this.cleanupTaskFiles(task, true);
    }
    this.tasks = this.tasks.filter((item: DownloadTask) => item.id !== taskId);
    this.notifyTasksChanged();
    if (!this.activeTaskId) {
      this.processQueue();
    }
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

    const fileName = this.getFileName(task.outputPath);
    const outputPath = `${destinationDir}/${fileName}`;
    fs.copyFileSync(task.outputPath, outputPath);
    logger.info(`Task ${task.id} exported to downloads: ${outputPath}`);
    this.deleteTask(task.id);
    return outputPath;
  }

  removeCompleted(): void {
    this.tasks = this.tasks.filter((task: DownloadTask) =>
      task.status === DownloadStatus.DOWNLOADING_VIDEO ||
      task.status === DownloadStatus.DOWNLOADING_AUDIO ||
      task.status === DownloadStatus.MERGING ||
      task.status === DownloadStatus.PENDING
    );
    this.notifyTasksChanged();
  }

  private notifyTasksChanged(): void {
    AppStorage.setOrCreate('downloadTasks', [...this.tasks]);
  }

  private async processQueue(): Promise<void> {
    if (this.activeTaskId) {
      return;
    }

    const pending = this.tasks.find((task: DownloadTask) => task.status === DownloadStatus.PENDING);
    if (!pending) {
      return;
    }

    this.activeTaskId = pending.id;
    try {
      await this.executeTask(pending);
    } catch (error) {
      if (!pending._cancelled) {
        pending.status = DownloadStatus.FAILED;
        pending.errorMessage = this.getErrorMessage(error);
      }
      logger.error(`Task ${pending.id} failed: ${this.getErrorMessage(error)}`);
    } finally {
      this.activeTaskId = null;
      this.notifyTasksChanged();
      this.processQueue();
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

    task.taskDir = this.ensureTaskDir(task);
    const videoExt = this.getFileExtension(task.videoStream);
    const audioExt = task.audioStream ? this.getFileExtension(task.audioStream) : '';
    task._videoFilePath = `${task.taskDir}/video.${videoExt}`;
    task._audioFilePath = task.audioStream ? `${task.taskDir}/audio.${audioExt}` : '';
    logger.info(`Task ${task.id} start: dir=${task.taskDir} totalSize=${task.totalSize || 'unknown'} video=${this.getStreamLogLabel(task.videoStream)} audio=${task.audioStream ? this.getStreamLogLabel(task.audioStream) : 'none'}`);

    task.status = DownloadStatus.DOWNLOADING_VIDEO;
    this.notifyTasksChanged();
    await this.downloadStream(task, task.videoStream, task._videoFilePath, 'video');
    if (task._cancelled) {
      return;
    }

    if (task.audioStream) {
      task.status = DownloadStatus.DOWNLOADING_AUDIO;
      this.notifyTasksChanged();
      await this.downloadStream(task, task.audioStream, task._audioFilePath, 'audio');
      if (task._cancelled) {
        return;
      }
    }

    task.status = DownloadStatus.MERGING;
    task.updateMergeProgress(5);
    logger.info(`Task ${task.id} merging`);
    this.notifyTasksChanged();

    task.outputPath = await this.mergeOrCopy(task);
    task.status = DownloadStatus.COMPLETED;
    task.progress = 100;
    task.videoProgress = 100;
    task.audioProgress = task.audioStream ? 100 : 0;
    task.mergeProgress = 100;
    this.cleanupTaskFiles(task, false);
    logger.info(`Task ${task.id} completed: output=${task.outputPath}`);
    this.notifyTasksChanged();
    await this.autoExportCompletedTask(task);
  }

  private async autoExportCompletedTask(task: DownloadTask): Promise<void> {
    if (!task._context || task.status !== DownloadStatus.COMPLETED || !task.outputPath) {
      return;
    }

    try {
      logger.info(`Task ${task.id} auto export prompt opening`);
      const documentViewPicker = new picker.DocumentViewPicker(task._context);
      const documentSaveOptions = new picker.DocumentSaveOptions();
      documentSaveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const result = await documentViewPicker.save(documentSaveOptions);
      if (!result || result.length === 0) {
        logger.info(`Task ${task.id} auto export cancelled`);
        return;
      }

      const destinationDir = new fileUri.FileUri(result[0]).path;
      const exportedPath = await this.exportCompletedTask(task.id, destinationDir);
      logger.info(`Task ${task.id} auto export completed: ${exportedPath}`);
    } catch (error) {
      logger.warn(`Task ${task.id} auto export failed: ${this.getErrorMessage(error)}`);
    }
  }

  private async downloadStream(
    task: DownloadTask,
    stream: StreamInfo,
    filePath: string,
    type: 'video' | 'audio'
  ): Promise<void> {
    const totalBytes = stream.contentLength || 0;
    const partCount = totalBytes > 0 ? Math.max(1, Math.min(task.threadCount, MAX_THREAD_COUNT)) : 1;
    logger.info(`Task ${task.id} ${type} download start: mode=${partCount > 1 ? 'range' : 'single'} parts=${partCount} size=${totalBytes || 'unknown'} stream=${this.getStreamLogLabel(stream)}`);

    if (partCount <= 1) {
      await this.downloadSingle(task, stream, filePath, type);
      return;
    }

    try {
      await this.downloadByRanges(task, stream, filePath, type, totalBytes, partCount);
    } catch (error) {
      if (task._cancelled) {
        return;
      }
      logger.warn(`Range download fallback for ${task.id}: ${this.getErrorMessage(error)}`);
      await this.downloadSingle(task, stream, filePath, type);
    }
  }

  private async downloadByRanges(
    task: DownloadTask,
    stream: StreamInfo,
    filePath: string,
    type: 'video' | 'audio',
    totalBytes: number,
    partCount: number
  ): Promise<void> {
    const partDir = `${task.taskDir}/${type}_parts`;
    this.ensureDir(partDir);

    const parts: RangePart[] = [];
    const baseSize = Math.floor(totalBytes / partCount);
    for (let i = 0; i < partCount; i++) {
      const start = i * baseSize;
      const end = i === partCount - 1 ? totalBytes - 1 : ((i + 1) * baseSize) - 1;
      parts.push({ index: i, start, end, filePath: `${partDir}/part_${i}` });
    }

    const progress: PartProgress = { total: totalBytes, parts: new Array(partCount).fill(0) };
    logger.info(`Task ${task.id} ${type} range download: ${partCount} parts ${totalBytes} bytes`);
    await Promise.all(parts.map((part: RangePart) =>
      this.downloadRangePart(task, stream, part, type, progress)));

    if (task._cancelled) {
      return;
    }

    this.concatPartFiles(parts, filePath);
    task.updateProgress(totalBytes, totalBytes, type);
    logger.info(`Task ${task.id} ${type} range download completed: ${filePath}`);
    this.notifyTasksChanged();
  }

  private async downloadRangePart(
    task: DownloadTask,
    stream: StreamInfo,
    part: RangePart,
    type: 'video' | 'audio',
    progress: PartProgress
  ): Promise<void> {
    const rangeSpec = `${part.start}-${part.end}`;
    const requestUrl = this.buildRangeUrl(stream.url, rangeSpec);
    const header: Record<string, string> = { 'Accept-Encoding': 'identity' };
    if (!this.isYoutubePlaybackUrl(stream.url)) {
      header['Range'] = `bytes=${rangeSpec}`;
    }
    const response = await this.requestArrayBuffer(requestUrl, header);

    if (task._cancelled) {
      return;
    }
    const expectedSize = part.end - part.start + 1;
    if (response.responseCode !== 206 && !(response.responseCode === 200 && (response.result as ArrayBuffer).byteLength === expectedSize)) {
      throw new Error(`Range request returned HTTP ${response.responseCode}`);
    }

    const data = response.result as ArrayBuffer;
    this.writeBufferToFile(part.filePath, data, (written: number) => {
      progress.parts[part.index] = written;
      const current = progress.parts.reduce((sum: number, value: number) => sum + value, 0);
      task.updateProgress(current, progress.total, type);
      this.notifyTasksChanged();
    }, task);
  }

  private async downloadSingle(
    task: DownloadTask,
    stream: StreamInfo,
    filePath: string,
    type: 'video' | 'audio'
  ): Promise<void> {
    logger.info(`Task ${task.id} ${type} single download request`);
    const response = await this.requestArrayBuffer(stream.url, { 'Accept-Encoding': 'identity' });
    if (task._cancelled) {
      return;
    }
    if (response.responseCode !== 200 && response.responseCode !== 206) {
      throw new Error(`HTTP ${response.responseCode}`);
    }

    const data = response.result as ArrayBuffer;
    const totalBytes = stream.contentLength && stream.contentLength > 0 ? stream.contentLength : data.byteLength;
    this.writeBufferToFile(filePath, data, (written: number) => {
      task.updateProgress(written, totalBytes, type);
      this.notifyTasksChanged();
    }, task);
    logger.info(`Task ${task.id} ${type} single download completed: ${filePath} bytes=${totalBytes}`);
  }

  private async requestArrayBuffer(url: string, header: Record<string, string>, redirectDepth: number = 0): Promise<http.HttpResponse> {
    if (redirectDepth > 5) {
      throw new Error('Too many redirects');
    }
    const httpRequest = http.createHttp();
    return new Promise<http.HttpResponse>((resolve, reject) => {
      httpRequest.request(
        url,
        {
          method: http.RequestMethod.GET,
          header,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 30000,
          readTimeout: 120000,
          usingCache: false
        },
        (error, data: http.HttpResponse) => {
          httpRequest.destroy();
          if (error) {
            reject(error);
            return;
          }

          const responseCode = data.responseCode || 0;
          if (responseCode >= 300 && responseCode < 400) {
            const headers = (data.header || {}) as Record<string, string | string[]>;
            const location = this.getRedirectLocation(headers);
            if (location) {
              this.requestArrayBuffer(location, header, redirectDepth + 1).then(resolve).catch(reject);
              return;
            }
          }
          resolve(data);
        }
      );
    });
  }

  private getRedirectLocation(headers: Record<string, string | string[]>): string | null {
    const keys = ['Location', 'location'];
    for (const key of keys) {
      const value = headers[key];
      if (typeof value === 'string' && value.length > 0) {
        return value;
      }
      if (Array.isArray(value) && value.length > 0 && value[0]) {
        return value[0];
      }
    }
    return null;
  }

  private writeBufferToFile(
    filePath: string,
    data: ArrayBuffer,
    onProgress: (written: number) => void,
    task: DownloadTask
  ): void {
    const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    try {
      let offset = 0;
      while (offset < data.byteLength) {
        if (task._cancelled) {
          return;
        }
        const end = Math.min(offset + WRITE_CHUNK_SIZE, data.byteLength);
        fs.writeSync(file.fd, data.slice(offset, end));
        offset = end;
        onProgress(offset);
      }
    } finally {
      fs.closeSync(file);
    }
  }

  private async mergeOrCopy(task: DownloadTask): Promise<string> {
    const safeTitle = this.sanitizeFilename(task.title || task.videoId);
    const outputExt = this.getOutputExtension(task);
    const outputPath = `${task.taskDir}/${safeTitle}.${outputExt}`;

    if (task.audioStream && task._audioFilePath) {
      logger.info(`Task ${task.id} ffmpeg merge output=${outputExt} videoExt=${this.getFileExtension(task.videoStream)} audioExt=${this.getFileExtension(task.audioStream)}`);
      const commands: string[] = [
        'ffmpeg',
        '-y',
        '-i',
        task._videoFilePath,
        '-i',
        task._audioFilePath,
        '-c',
        'copy',
        outputPath
      ];
      await FFmpeg.execute(commands, {
        logCallback: (message: string) => {
          logger.debug(`[ffmpeg] ${message}`);
        },
        progressCallback: (_message: string) => {
          task.updateMergeProgress(Math.max(task.mergeProgress, 50));
          this.notifyTasksChanged();
        }
      });
      task.updateMergeProgress(100);
    } else {
      fs.copyFileSync(task._videoFilePath, outputPath);
      task.updateMergeProgress(100);
    }

    logger.info(`File saved to app downloads: ${outputPath}`);
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

  private concatPartFiles(parts: RangePart[], outputPath: string): void {
    const outputFile = fs.openSync(outputPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    try {
      parts.sort((a: RangePart, b: RangePart) => a.index - b.index).forEach((part: RangePart) => {
        const stat = fs.statSync(part.filePath);
        const inputFile = fs.openSync(part.filePath, fs.OpenMode.READ_ONLY);
        try {
          const buffer = new ArrayBuffer(stat.size);
          const read = fs.readSync(inputFile.fd, buffer);
          if (read > 0) {
            fs.writeSync(outputFile.fd, buffer.slice(0, read));
          }
        } finally {
          fs.closeSync(inputFile);
        }
      });
    } finally {
      fs.closeSync(outputFile);
    }
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
