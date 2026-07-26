export class VideoItem {
  id: number;
  videoId: string;
  channelId: string;
  title: string;
  author: string;
  viewCount: string;
  thumbnailUrl: string;
  thumbnailColor: string;
  isLive: boolean;
  isPremium: boolean;
  requiresMembership: boolean;
  channelAvatarUrl: string;
  channelHandle: string;
  videoDescription: string;
  videoDescriptionError: string | null;
  /** 发布时间的本地化相对文本（如 "3 days ago" / "3 天前"），由 entry 侧解析；无则空串 */
  publishedTimeText: string = '';

  constructor(
    id: number,
    videoId: string,
    title: string,
    author: string,
    viewCount: string,
    thumbnailUrl: string,
    isLive: boolean = true,
    thumbnailColor: string = "#CCCCCC",
    channelId: string = "",
    channelAvatarUrl: string = "",
    channelHandle: string = "",
    videoDescription: string = "",
    videoDescriptionError: string | null = null,
    isPremium: boolean = false,
    requiresMembership: boolean = false
  ) {
    this.id = id;
    this.videoId = videoId;
    this.title = title;
    this.author = author;
    this.viewCount = viewCount;
    this.thumbnailUrl = thumbnailUrl;
    this.isLive = isLive;
    this.isPremium = isPremium;
    this.requiresMembership = requiresMembership;
    this.thumbnailColor = thumbnailColor;
    this.channelId = channelId;
    this.channelAvatarUrl = channelAvatarUrl;
    this.channelHandle = channelHandle;
    this.videoDescription = videoDescription;
    this.videoDescriptionError = videoDescriptionError;
  }
}

export interface IDataSource {
  totalCount(): number;
  getData(index: number): VideoItem;
  registerDataChangeListener(listener: DataChangeListener): void;
  unregisterDataChangeListener(listener: DataChangeListener): void;
}

export interface DataChangeListener {
  onDataReloaded(): void;
  onDataAdd(index: number): void;
  onDataDelete(index: number): void;
  onDataChange(index: number): void;
  onDataMove(from: number, to: number): void;
}

export class VideoDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private dataArray: VideoItem[] = [];

  public totalCount(): number {
    return this.dataArray.length;
  }

  public getData(index: number): VideoItem {
    return this.dataArray[index];
  }

  public addData(index: number, data: VideoItem): void {
    this.dataArray.splice(index, 0, data);
    this.notifyDataAdd(index);
  }

  public pushData(data: VideoItem): void {
    this.dataArray.push(data);
    this.notifyDataAdd(this.dataArray.length - 1);
  }

  public setData(data: VideoItem[]): void {
    this.dataArray = data;
    this.notifyDataReload();
  }

  public getDataList(): VideoItem[] {
    return this.dataArray;
  }

  public addAll(data: VideoItem[]): void {
    if (data.length === 0) {
      return;
    }
    const startIndex = this.dataArray.length;
    this.dataArray = this.dataArray.concat(data);
    this.notifyDataReload();
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  notifyDataReload(): void {
    this.listeners.forEach(listener => {
      listener.onDataReloaded();
    })
  }

  notifyDataAdd(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataAdd(index);
    })
  }

  notifyDataDelete(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataDelete(index);
    })
  }

  notifyDataChange(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataChange(index);
    })
  }

  notifyDataMove(from: number, to: number): void {
    this.listeners.forEach(listener => {
      listener.onDataMove(from, to);
    })
  }
}
