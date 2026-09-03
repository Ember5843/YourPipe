/**
 * 信息流 LazyForEach 数据源。
 * 范式同 youtube_core/common/VideoModel.ets 的 VideoDataSource（IDataSource +
 * DataChangeListener），但元素类型放开为 Object，供 VideoItem / SearchInfoItem /
 * SubscriptionFeedItem / SearchPlaylistItem 等各类信息流复用。
 *
 * 页面仍持有自己的强类型数组（唯一事实来源），数组每次整体重赋值后调用
 * setData 同步本数据源；提供 keyOf 时做前缀比对：旧数据是新数据的严格前缀
 * （翻页 append）→ 逐项 onDataAdd 增量通知；key 序列完全一致（同长度同序，
 * 含内容未变的重复同步）→ 不触发全量重载，仅对引用变化的条目逐项
 * onDataChange 原地刷新（不重建节点、不重播条目转场）；其余情况
 * onDataReloaded 全量刷新（替代原先靠 key 里嵌 epoch 强刷重建的 hack）。
 */
import { IDataSourcePrefetching } from '@kit.ArkUI';
import { FeedThumbUrlOf, ThumbPrefetcher } from './ThumbPrefetcher';

export type FeedItemKeyOf = (item: Object, index: number) => string;

export class FeedDataSource implements IDataSourcePrefetching {
  /** 缩略图预取 URL 提取器；MediaVideoFeed 挂载时注入（缺省 defaultFeedThumbUrl） */
  thumbUrlOf: FeedThumbUrlOf | null = null;
  private listeners: DataChangeListener[] = [];
  private dataArray: Object[] = [];
  private keys: string[] = [];

  public totalCount(): number {
    return this.dataArray.length;
  }

  public getData(index: number): Object {
    return this.dataArray[index];
  }

  public getDataList(): Object[] {
    return this.dataArray;
  }

  public setData(data: Object[], keyOf?: FeedItemKeyOf): void {
    const nextData: Object[] = data.slice();
    if (keyOf) {
      const nextKeys: string[] = nextData.map((item: Object, index: number) => keyOf(item, index));
      let prefix: number = 0;
      const limit: number = Math.min(this.keys.length, nextKeys.length);
      while (prefix < limit && this.keys[prefix] === nextKeys[prefix]) {
        prefix++;
      }
      const isPureAppend: boolean = this.keys.length > 0
        && prefix === this.keys.length
        && nextKeys.length > this.keys.length;
      // key 序列完全一致（同长度同序）
      const isSameKeys: boolean = prefix === nextKeys.length && this.keys.length === nextKeys.length;
      const oldData: Object[] = this.dataArray;
      this.dataArray = nextData;
      this.keys = nextKeys;
      if (isPureAppend) {
        for (let i = prefix; i < nextKeys.length; i++) {
          this.notifyDataAdd(i);
        }
        return;
      }
      // 不触发全量重载——避免订阅合并/原位更新/重复同步把可见条目重建重播入场动画。
      // 仅对引用变化的条目逐项 notifyDataChange（原地刷新内容，不重建节点、不重播转场）。
      if (isSameKeys) {
        for (let i = 0; i < nextKeys.length; i++) {
          if (oldData[i] !== nextData[i]) {
            this.notifyDataChange(i);
          }
        }
        return;
      }
      this.notifyDataReload();
      return;
    }
    this.dataArray = nextData;
    this.keys = [];
    this.notifyDataReload();
  }

  // ── IDataSourcePrefetching：配合 BasicPrefetcher 在滑动前预取缩略图 ──

  prefetch(index: number): void {
    const url: string = this.thumbUrlAt(index);
    if (url.length > 0) {
      ThumbPrefetcher.getInstance().prefetchUrl(url);
    }
  }

  cancel(index: number): void {
    const url: string = this.thumbUrlAt(index);
    if (url.length > 0) {
      ThumbPrefetcher.getInstance().cancelUrl(url);
    }
  }

  private thumbUrlAt(index: number): string {
    if (!this.thumbUrlOf || index < 0 || index >= this.dataArray.length) {
      return '';
    }
    try {
      return this.thumbUrlOf(this.dataArray[index]);
    } catch {
      return '';
    }
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  notifyDataReload(): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    })
  }

  notifyDataAdd(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataAdd(index);
    })
  }

  notifyDataDelete(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataDelete(index);
    })
  }

  notifyDataChange(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataChange(index);
    })
  }

  notifyDataMove(from: number, to: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataMove(from, to);
    })
  }
}
