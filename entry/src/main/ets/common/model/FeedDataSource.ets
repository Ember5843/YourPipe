/**
 * 信息流 LazyForEach 数据源（API 12+ onDatasetChange 原子差量通知）。
 *
 * 页面仍持有自己的强类型数组（唯一事实来源），数组每次变更后调用
 * setData 同步本数据源；提供 keyOf 时做差量分析：
 * 1. 严格前缀追加（翻页 append）→ DataOperationType.ADD；
 * 2. 同长度同序（原地刷新内容）→ 仅对引用变化的索引发 DataOperationType.CHANGE；
 * 3. 纯删除子序列（如隐藏/移除若干条目）→ 倒序发精确 DataOperationType.DELETE；
 * 4. 其余全量变更（刷新/换源）→ DataOperationType.RELOAD。
 *
 * 严格只使用 onDatasetChange，不混用旧的 onDataAdd/onDataDelete/onDataReloaded。
 */
import { IDataSourcePrefetching } from '@kit.ArkUI';
import { FeedThumbUrlOf, ThumbPrefetcher } from './ThumbPrefetcher';

export type FeedItemKeyOf = (item: Object, index: number) => string;
export type FeedItemFilter = (item: Object) => boolean;

export class FeedDataSource implements IDataSourcePrefetching {
  /** 缩略图预取 URL 提取器；MediaVideoFeed 挂载时注入（缺省 defaultFeedThumbUrl） */
  thumbUrlOf: FeedThumbUrlOf | null = null;
  /** 展示层过滤（如 AiSList 隐藏模式）：在 key 计算前剔除条目，索引保持一致。 */
  itemFilter: FeedItemFilter | null = null;
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
    const filter: FeedItemFilter | null = this.itemFilter;
    const source: Object[] = filter ? data.filter((item: Object) => filter(item)) : data;
    const nextData: Object[] = source.slice();
    if (keyOf) {
      const nextKeys: string[] = nextData.map((item: Object, index: number) => keyOf(item, index));
      const oldKeys: string[] = this.keys;
      const oldData: Object[] = this.dataArray;
      let prefix: number = 0;
      const limit: number = Math.min(oldKeys.length, nextKeys.length);
      while (prefix < limit && oldKeys[prefix] === nextKeys[prefix]) {
        prefix++;
      }
      const isPureAppend: boolean = oldKeys.length > 0
        && prefix === oldKeys.length
        && nextKeys.length > oldKeys.length;
      const isSameKeys: boolean = prefix === nextKeys.length && oldKeys.length === nextKeys.length;

      this.dataArray = nextData;
      this.keys = nextKeys;

      if (isPureAppend) {
        this.notifyDatasetChange([{
          type: DataOperationType.ADD,
          index: prefix,
          count: nextKeys.length - prefix
        }]);
        return;
      }

      if (isSameKeys) {
        const ops: DataOperation[] = [];
        for (let i = 0; i < nextKeys.length; i++) {
          if (oldData[i] !== nextData[i]) {
            ops.push({ type: DataOperationType.CHANGE, index: i });
          }
        }
        if (ops.length > 0) {
          this.notifyDatasetChange(ops);
        }
        return;
      }

      // 纯删除检测：nextKeys 是 oldKeys 的严格保序子序列 → 发精确 DELETE 差量，避免整列重建闪烁。
      if (oldKeys.length > 0 && nextKeys.length > 0 && nextKeys.length < oldKeys.length) {
        const deletedIndices: number[] = [];
        let ni: number = 0;
        for (let oi = 0; oi < oldKeys.length; oi++) {
          if (ni < nextKeys.length && oldKeys[oi] === nextKeys[ni]) {
            ni++;
          } else {
            deletedIndices.push(oi);
          }
        }
        if (ni === nextKeys.length && deletedIndices.length > 0) {
          const ops: DataOperation[] = [];
          for (let k = deletedIndices.length - 1; k >= 0; k--) {
            ops.push({ type: DataOperationType.DELETE, index: deletedIndices[k], count: 1 });
          }
          this.notifyDatasetChange(ops);
          return;
        }
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

  notifyDatasetChange(operations: DataOperation[]): void {
    if (operations.length === 0) {
      return;
    }
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDatasetChange(operations);
    });
  }

  notifyDataReload(): void {
    this.notifyDatasetChange([{ type: DataOperationType.RELOAD }]);
  }

  notifyDataAdd(index: number): void {
    this.notifyDatasetChange([{ type: DataOperationType.ADD, index: index, count: 1 }]);
  }

  notifyDataDelete(index: number): void {
    this.notifyDatasetChange([{ type: DataOperationType.DELETE, index: index, count: 1 }]);
  }

  notifyDataChange(index: number): void {
    this.notifyDatasetChange([{ type: DataOperationType.CHANGE, index: index }]);
  }

  notifyDataMove(from: number, to: number): void {
    this.notifyDatasetChange([{ type: DataOperationType.MOVE, index: { from: from, to: to } }]);
  }
}
