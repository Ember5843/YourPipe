import { AppLog } from './AppLog';
import { StreamInfo, PlayerModel } from 'mediaservice';
import common from '@ohos.app.ability.common';
import { fileIo as fs, picker, fileUri as fileUriKit } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';

const logger = AppLog.getInstance('DownloadManager');

export enum DownloadStatus {
  PENDING = 'pending',
  DOWNLOADING_VIDEO = 'downloading_video',
  DOWNLOADING_AUDIO = 'downloading_audio',
  MERGING = 'merging',
  COMPLETED = 'completed',
  FAILED = 'failed',
  CANCELLED = 'cancelled'
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
  @Track status: DownloadStatus = DownloadStatus.PENDING;
  @Track progress: number = 0;
  @Track videoProgress: number = 0;
  @Track audioProgress: number = 0;
  @Track totalSize: number = 0;
  @Track downloadedSize: number = 0;
  @Track errorMessage: string = '';
  @Track outputPath: string = '';
  createdAt: number = Date.now();

  _cancelled: boolean = false;
  _videoFilePath: string = '';
  _audioFilePath: string = '';
  _context: common.UIAbilityContext | null = null;

  private _lastProgressUpdate: number = 0;
  private _lastReportedProgress: number = -1;

  constructor(
    id: string, videoId: string, title: string, author: string,
    thumbnailUrl: string, videoStream: StreamInfo, audioStream: StreamInfo | null
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
    const now = Date.now();
    const pct = total > 0 ? Math.min(Math.round((bytesDownloaded / total) * 100), 100) : 0;
    const shouldUpdate =
      now - this._lastProgressUpdate >= 300 ||
      Math.abs(pct - this._lastReportedProgress) >= 1 ||
      pct >= 100;

    if (!shouldUpdate && this._lastReportedProgress >= 0) {
      return;
    }

    this._lastProgressUpdate = now;
    this._lastReportedProgress = pct;

    if (type === 'video') {
      this.videoProgress = pct;
    } else {
      this.audioProgress = pct;
    }

    if (this.audioStream) {
      this.progress = Math.round(this.videoProgress * 0.7 + this.audioProgress * 0.3);
    } else {
      this.progress = this.videoProgress;
    }

    this.downloadedSize = bytesDownloaded;
  }

  getStatusLabel(): string {
    switch (this.status) {
      case DownloadStatus.PENDING: return '等待中';
      case DownloadStatus.DOWNLOADING_VIDEO: return '下载视频';
      case DownloadStatus.DOWNLOADING_AUDIO: return '下载音频';
      case DownloadStatus.MERGING: return '合并中';
      case DownloadStatus.COMPLETED: return '已完成';
      case DownloadStatus.FAILED: return '失败';
      case DownloadStatus.CANCELLED: return '已取消';
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
  private _tasksSnapshot: DownloadTask[] = [];

  static getInstance(): DownloadManager {
    if (!DownloadManager.instance) {
      DownloadManager.instance = new DownloadManager();
    }
    return DownloadManager.instance;
  }

  getTasks(): DownloadTask[] {
    return this.tasks;
  }

  private notifyTasksChanged(): void {
    this._tasksSnapshot = [...this.tasks];
    AppStorage.setOrCreate('downloadTasks', this._tasksSnapshot);
  }

  addTask(task: DownloadTask): void {
    this.tasks.unshift(task);
    this.notifyTasksChanged();
    this.processQueue();
  }

  cancelTask(taskId: string): void {
    const task = this.tasks.find(t => t.id === taskId);
    if (task && task.status !== DownloadStatus.COMPLETED) {
      task._cancelled = true;
      task.status = DownloadStatus.CANCELLED;
      this.notifyTasksChanged();
    }
  }

  deleteTask(taskId: string): void {
    const idx = this.tasks.findIndex(t => t.id === taskId);
    if (idx !== -1) {
      this.cleanupTaskFiles(this.tasks[idx]);
    }
    this.tasks = this.tasks.filter(t => t.id !== taskId);
    if (this.activeTaskId === taskId) {
      this.activeTaskId = null;
    }
    this.notifyTasksChanged();
    if (!this.activeTaskId) {
      this.processQueue();
    }
  }

  removeCompleted(): void {
    this.tasks = this.tasks.filter(t =>
      t.status === DownloadStatus.DOWNLOADING_VIDEO ||
      t.status === DownloadStatus.DOWNLOADING_AUDIO ||
      t.status === DownloadStatus.MERGING ||
      t.status === DownloadStatus.PENDING
    );
    this.notifyTasksChanged();
  }

  setContext(ctx: common.UIAbilityContext): void {
    this.tasks.forEach(t => t._context = ctx);
  }

  private async processQueue(): Promise<void> {
    if (this.activeTaskId) return;

    const pending = this.tasks.find(t => t.status === DownloadStatus.PENDING);
    if (!pending) return;

    this.activeTaskId = pending.id;
    try {
      await this.executeTask(pending);
    } catch (e) {
      logger.error(`Task ${pending.id} failed: ${JSON.stringify(e)}`);
    } finally {
      this.activeTaskId = null;
      this.notifyTasksChanged();
      this.processQueue();
    }
  }

  private async executeTask(task: DownloadTask): Promise<void> {
    if (task._cancelled) return;
    if (!task._context) {
      task.status = DownloadStatus.FAILED;
      task.errorMessage = '缺少上下文';
      return;
    }

    const tempDir = task._context.tempDir;

    // Step 1: Download video
    task.status = DownloadStatus.DOWNLOADING_VIDEO;
    this.notifyTasksChanged();

    const videoExt = this.getFileExtension(task.videoStream);
    task._videoFilePath = `${tempDir}/${task.id}_video.${videoExt}`;
    try {
      await this.downloadFile(task, task.videoStream, task._videoFilePath, 'video');
    } catch (e) {
      if (!task._cancelled) {
        task.status = DownloadStatus.FAILED;
        task.errorMessage = `视频下载失败: ${e}`;
        this.notifyTasksChanged();
      }
      return;
    }
    if (task._cancelled) return;

    // Step 2: Download audio (if any)
    if (task.audioStream) {
      task.status = DownloadStatus.DOWNLOADING_AUDIO;
      this.notifyTasksChanged();

      const audioExt = this.getFileExtension(task.audioStream);
      task._audioFilePath = `${tempDir}/${task.id}_audio.${audioExt}`;
      try {
        await this.downloadFile(task, task.audioStream, task._audioFilePath, 'audio');
      } catch (e) {
        if (!task._cancelled) {
          task.status = DownloadStatus.FAILED;
          task.errorMessage = `音频下载失败: ${e}`;
          this.notifyTasksChanged();
        }
        return;
      }
      if (task._cancelled) return;
    }

    // Step 3: Merge and save
    task.status = DownloadStatus.MERGING;
    this.notifyTasksChanged();

    try {
      const outputPath = await this.mergeAndSave(task);
      task.outputPath = outputPath;
      task.status = DownloadStatus.COMPLETED;
      task.progress = 100;
      task.videoProgress = 100;
      if (task.audioStream) {
        task.audioProgress = 100;
      }
      this.notifyTasksChanged();
      this.cleanupTaskFiles(task);
    } catch (e) {
      if (!task._cancelled) {
        task.status = DownloadStatus.FAILED;
        task.errorMessage = `保存失败: ${e}`;
        this.notifyTasksChanged();
      }
    }
  }

  private async downloadFile(
    task: DownloadTask, stream: StreamInfo, filePath: string, type: 'video' | 'audio'
  ): Promise<void> {
    const totalBytes = stream.contentLength || 0;
    let downloadedBytes = 0;
    let file: fs.File | null = null;

    try {
      file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);

      const httpRequest = http.createHttp();
      const response = await httpRequest.request(
        stream.url,
        {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 30000,
          readTimeout: 120000,
        }
      );

      if (task._cancelled) return;

      const code = response.responseCode;
      if (code === 200 || code === 206) {
        const data = response.result as ArrayBuffer;
        if (data && data.byteLength > 0) {
          const chunkSize = 256 * 1024;
          let offset = 0;
          while (offset < data.byteLength) {
            if (task._cancelled) return;
            const end = Math.min(offset + chunkSize, data.byteLength);
            const chunk = data.slice(offset, end);
            fs.writeSync(file.fd, chunk);
            downloadedBytes = end;
            task.updateProgress(
              downloadedBytes,
              totalBytes > 0 ? totalBytes : data.byteLength,
              type
            );
            offset = end;
          }
        }
      } else {
        throw new Error(`HTTP ${code}`);
      }

      httpRequest.destroy();
    } finally {
      if (file) {
        try { fs.closeSync(file); } catch (_e) {
        }
      }
    }
  }

  private async mergeAndSave(task: DownloadTask): Promise<string> {
    if (!task._context) throw new Error('缺少上下文');

    const context = task._context;
    const filePicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSaveOptions();

    const safeTitle = this.sanitizeFilename(task.title || task.videoId);
    const safeAuthor = task.author ? this.sanitizeFilename(task.author) : '';
    const baseName = safeAuthor ? `${safeTitle}_${safeAuthor}` : safeTitle;
    const ext = this.getFileExtension(task.videoStream);
    const fileName = `${baseName}.${ext}`;

    options.newFileNames = [fileName];
    options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;

    const result = await filePicker.save(options);
    if (!result || result.length === 0) {
      throw new Error('用户取消了保存');
    }

    const uriPath = result[0];
    const uri = new fileUriKit.FileUri(uriPath + '/' + fileName);
    const outputPath = uri.path;

    if (task.audioStream && task._audioFilePath) {
      this.concatFiles(task._videoFilePath, task._audioFilePath, outputPath);
    } else {
      fs.copyFileSync(task._videoFilePath, outputPath);
    }

    logger.info(`File saved to: ${outputPath}`);
    return outputPath;
  }

  private concatFiles(videoPath: string, audioPath: string, outputPath: string): void {
    const outputFile = fs.openSync(outputPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);

    try {
      const videoStat = fs.statSync(videoPath);
      const videoFile = fs.openSync(videoPath, fs.OpenMode.READ_ONLY);
      const videoBuffer = new ArrayBuffer(videoStat.size);
      const videoRead = fs.readSync(videoFile.fd, videoBuffer);
      if (videoRead > 0) {
        fs.writeSync(outputFile.fd, videoBuffer.slice(0, videoRead));
      }
      fs.closeSync(videoFile);

      const audioStat = fs.statSync(audioPath);
      const audioFile = fs.openSync(audioPath, fs.OpenMode.READ_ONLY);
      const audioBuffer = new ArrayBuffer(audioStat.size);
      const audioRead = fs.readSync(audioFile.fd, audioBuffer);
      if (audioRead > 0) {
        fs.writeSync(outputFile.fd, audioBuffer.slice(0, audioRead));
      }
      fs.closeSync(audioFile);
    } finally {
      fs.closeSync(outputFile);
    }
  }

  private cleanupTaskFiles(task: DownloadTask): void {
    [task._videoFilePath, task._audioFilePath].forEach(p => {
      if (p && p.length > 0) {
        try {
          if (fs.accessSync(p)) {
            fs.unlinkSync(p);
          }
        } catch (_e) {
        }
      }
    });
  }

  private getFileExtension(stream: StreamInfo): string {
    const mime = (stream.mimeType || '').toLowerCase();
    if (mime.includes('mp4')) return 'mp4';
    if (mime.includes('webm')) return 'webm';
    if (mime.includes('3gpp')) return '3gp';
    if (mime.includes('mpeg') && !stream.videoQuality) return 'mp3';
    if (mime.includes('aac')) return 'aac';
    if (mime.includes('ogg') || mime.includes('opus')) return 'opus';
    const kind = (stream.kind || '').toLowerCase();
    if (kind.includes('audio')) return 'm4a';
    return 'mp4';
  }

  private sanitizeFilename(name: string): string {
    return name.replace(/[\\/:*?"<>|]/g, '_')
      .replace(/\s+/g, '_')
      .substring(0, 80)
      .trim();
  }
}
