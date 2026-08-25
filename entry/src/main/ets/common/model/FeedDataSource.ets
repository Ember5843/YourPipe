/**
 * 信息流 LazyForEach 数据源。
 * 范式同 youtube_core/common/VideoModel.ets 的 VideoDataSource（IDataSource +
 * DataChangeListener），但元素类型放开为 Object，供 VideoItem / SearchInfoItem /
 * SubscriptionFeedItem / SearchPlaylistItem 等各类信息流复用。
 *
 * 页面仍持有自己的强类型数组（唯一事实来源），数组每次整体重赋值后调用
 * setData 同步本数据源；提供 keyOf 时做前缀比对：旧数据是新数据的严格前缀
 * （翻页 append）→ 逐项 onDataAdd 增量通知，其余情况 onDataReloaded 全量刷新
 * （替代原先靠 key 里嵌 epoch 强刷重建的 hack）。
 */
export type FeedItemKeyOf = (item: Object, index: number) => string;

export class FeedDataSource implements IDataSource {
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
      this.dataArray = nextData;
      this.keys = nextKeys;
      if (isPureAppend) {
        for (let i = prefix; i < nextKeys.length; i++) {
          this.notifyDataAdd(i);
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
