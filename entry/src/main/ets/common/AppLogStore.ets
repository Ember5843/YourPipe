/**
 * AppLogStore.ets - 应用日志全局存储管理器（会话模式，支持磁盘持久化）
 *
 * 数据模型：每次「开启日志」创建一个 LogSession，关闭时封存。
 * 持久化：每次开启日志在应用私有目录 files/logs/ 下创建新日志文件，
 *         以 JSON Lines 格式追加写入，应用重启后自动加载历史 Session。
 * 响应式设计：
 *   - LogSession 使用 @Observed，供 SessionCard 通过 @ObjectLink 细粒度订阅
 *   - AppStorage key 'appLogSessions' 存 LogSession[]，供 LogPage 通过 @StorageLink 感知列表变化
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

// ─── 数据类型 ────────────────────────────────────────────────────────────────

export type LogLevel = 'DEBUG' | 'INFO' | 'WARN' | 'ERROR' | 'FATAL';

/** 获取日志级别的数值优先级，用于过滤比较 */
function getLogLevelPriority(level: LogLevel): number {
  switch (level) {
    case 'DEBUG': return 0;
    case 'INFO': return 1;
    case 'WARN': return 2;
    case 'ERROR': return 3;
    case 'FATAL': return 4;
  }
}

/** 全局默认最小日志级别（低于此级别的日志不会写入内存/磁盘） */
const DEFAULT_MIN_LOG_LEVEL: LogLevel = 'INFO';

export interface LogData {
  /** 日志级别 */
  level: LogLevel;
  /** 日志标签 */
  tag: string;
  /** 日志正文 */
  message: string;
  /** 时间戳（毫秒） */
  time: number;
}

/**
 * 日志会话。
 * @Observed 使得 ArkUI 可通过 @ObjectLink 订阅其属性变化。
 * push() 中通过替换 logs 数组引用触发 @ObjectLink 刷新，
 * 进而令 SessionCard 中的 session.logCount 展示实时计数。
 */
@Observed
export class LogSession {
  /**
   * 唯一 ID，使用创建时的时间戳字符串。
   * 渲染时由 ForEach key 函数读取，必须 @Track。
   */
  @Track id: string;
  /**
   * 会话开始时间戳（ms）。
   * 渲染时在 SessionCard 中用于显示时间，必须 @Track。
   */
  @Track startTime: number;
  /**
   * 会话结束时间戳（ms），null 表示正在记录。
   * 封存时由 null 变为具体值，触发卡片状态标签刷新。
   */
  @Track endTime: number | null;
  /**
   * 当前会话内的日志行列表（最新在前）。
   * 每次 push 都会替换为新数组引用，@ObjectLink 因此感知到变化并刷新计数。
   */
  @Track logs: LogData[];
  /** 关联的磁盘日志文件路径（内部使用，不参与 UI 渲染） */
  filePath: string;

  constructor(id: string, startTime: number, filePath: string = '') {
    this.id = id;
    this.startTime = startTime;
    this.endTime = null;
    this.logs = [];
    this.filePath = filePath;
  }

  // 注意：不在此定义 getter。
  // HarmonyOS @Track 严格模式下，@ObjectLink 渲染时只能访问 @Track 装饰的实例属性，
  // getter 不在追踪范围内，访问会抛 BusinessError。
  // 请在 SessionCard.build() 中直接使用 session.logs.length 和 session.endTime === null。
}

// ─── 内部常量 ─────────────────────────────────────────────────────────────────

/** AppStorage 中 LogSession[] 的 key */
const SESSIONS_KEY = 'appLogSessions';
/** 单个 Session 内最大保留日志条数 */
const MAX_LOG_COUNT = 1000;
/** 最多保留的 Session 数量（超出时丢弃最旧） */
const MAX_SESSION_COUNT = 10;

/** 日志文件目录名 */
const LOGS_DIR = 'logs';
/** 日志文件名前缀 */
const LOG_FILE_PREFIX = 'yourpipe_';
/** 日志文件扩展名 */
const LOG_FILE_SUFFIX = '.log';
/** 磁盘上最多保留的历史日志文件数 */
const MAX_HISTORY_FILES = 30;

// ─── 公共管理类 ───────────────────────────────────────────────────────────────

export class AppLogStore {
  private static initialized: boolean = false;
  /** 当前是否处于监听（开启）状态 */
  private static enabled: boolean = false;
  /** 当前最小日志级别，低于此级别的日志不会存入 AppLogStore */
  private static minLevel: LogLevel = DEFAULT_MIN_LOG_LEVEL;

  /** 由外部注入：用于在 enable 时启动 native 日志转发 */
  private static nativeStartFn: (() => void) | null = null;
  /** 由外部注入：用于在 disable 时停止 native 日志转发 */
  private static nativeStopFn: (() => void) | null = null;

  /** 日志文件存放目录（应用私有目录下的 logs/） */
  private static logsDir: string = '';
  /** 当前活跃 Session 对应的文件对象 */
  private static currentFile: fs.File | null = null;
  /** 当前活跃 Session 的 ID */
  private static currentSessionId: string = '';
  /** 历史日志是否已从磁盘加载（延迟到日志页首次打开） */
  private static historyLoaded: boolean = false;
  /** 待落盘的序列化日志行（批量写盘缓冲） */
  private static pendingLines: string[] = [];
  /** 是否已有批量刷新定时器在跑（UI 引用替换 + 写盘合并） */
  private static flushScheduled: boolean = false;
  /** 批量刷新间隔：UI 引用替换与写盘都按此合并 */
  private static readonly FLUSH_INTERVAL_MS: number = 500;
  /** 缓冲达到该条数时立即刷新，不等定时器 */
  private static readonly FLUSH_IMMEDIATE_COUNT: number = 64;
  /** push 后是否有未触发 UI 刷新的内存变更 */
  private static pendingUiDirty: boolean = false;

  /**
   * 注入 native 日志桥接回调。
   */
  static setNativeBridge(startFn: () => void, stopFn: () => void): void {
    AppLogStore.nativeStartFn = startFn;
    AppLogStore.nativeStopFn = stopFn;
    if (AppLogStore.enabled) {
      startFn();
    }
  }

  /**
   * 在 EntryAbility.onCreate 中尽早调用。
   * 若 enableLogger=true，立即创建第一个 Session 开始记录。
   */
  static init(enableLogger: boolean, filesDir?: string): void {
    if (!AppLogStore.initialized) {
      AppStorage.setOrCreate<LogSession[]>(SESSIONS_KEY, []);
      AppLogStore.initialized = true;
    }

    // 初始化文件系统：只记录目录；历史日志延迟到日志页首次打开时再读盘，
    // 避免启动时无条件全量解析历史文件。
    if (filesDir) {
      try {
        AppLogStore.logsDir = filesDir + '/' + LOGS_DIR;
        AppLogStore.ensureLogsDir();
      } catch (e) {
        hilog.error(0xFF00, 'AppLogStore', 'init filesystem failed: %{public}s', JSON.stringify(e));
      }
    }

    AppLogStore.enabled = enableLogger;
    if (enableLogger) {
      AppLogStore.createNewSession();
    }
    hilog.info(0xFF00, 'AppLogStore', 'initialized enabled=%{public}s dir=%{public}s',
      String(enableLogger), AppLogStore.logsDir || '(memory-only)');
  }

  /**
   * 开始记录日志（Toggle 打开时调用）。
   * 封存已有活跃 Session（若存在），然后创建新 Session。
   */
  static startListening(): void {
    AppLogStore.enabled = true;
    AppLogStore.sealActiveSessions();
    AppLogStore.createNewSession();
    if (AppLogStore.nativeStartFn) {
      AppLogStore.nativeStartFn();
    }
    hilog.info(0xFF00, 'AppLogStore', 'listening started session=%{public}s', AppLogStore.currentSessionId);
  }

  /**
   * 停止记录日志（Toggle 关闭时调用）。
   * 封存当前活跃 Session。
   */
  static stopListening(): void {
    AppLogStore.enabled = false;
    AppLogStore.sealActiveSessions();
    if (AppLogStore.nativeStopFn) {
      AppLogStore.nativeStopFn();
    }
    hilog.info(0xFF00, 'AppLogStore', 'listening stopped');
  }

  /** 是否正在记录 */
  static get isListening(): boolean {
    return AppLogStore.enabled;
  }

  /**
   * 写入一条日志到当前活跃 Session。
   * 通过替换 session.logs 引用触发 @ObjectLink 刷新，
   * 再替换 sessions 数组引用触发 @StorageLink 刷新。
   * 同时追加到当前磁盘日志文件。
   */
  /**
   * 设置最小日志级别（动态调整，无需重启）。
   * 例如设为 'INFO' 时，DEBUG 日志不会写入 AppLogStore，但仍会输出到 hilog。
   */
  static setMinLevel(level: LogLevel): void {
    AppLogStore.minLevel = level;
  }

  static getMinLevel(): LogLevel {
    return AppLogStore.minLevel;
  }

  static push(level: LogLevel, tag: string, message: string): void {
    if (!AppLogStore.enabled) {
      return;
    }
    if (getLogLevelPriority(level) < getLogLevelPriority(AppLogStore.minLevel)) {
      return;
    }
    const sessions = AppStorage.get<LogSession[]>(SESSIONS_KEY);
    if (!sessions) {
      return;
    }
    const active = sessions.find(s => s.endTime === null);
    if (!active) {
      return;
    }

    const entry: LogData = { level, tag, message, time: Date.now() };
    // 原地写入内存与写盘缓冲；@ObjectLink/@StorageLink 的引用替换和磁盘写入
    // 由 flushPending 按 FLUSH_INTERVAL_MS 合并执行，避免每条日志 O(n) 拷贝 +
    // 一次同步写盘。
    active.logs.unshift(entry);
    if (active.logs.length > MAX_LOG_COUNT) {
      active.logs.length = MAX_LOG_COUNT;
    }
    AppLogStore.pendingLines.push(JSON.stringify(entry) + '\n');
    AppLogStore.pendingUiDirty = true;
    if (AppLogStore.pendingLines.length >= AppLogStore.FLUSH_IMMEDIATE_COUNT) {
      AppLogStore.flushPending();
    } else {
      AppLogStore.scheduleFlush();
    }
  }

  /** 日志页首次打开时调用：从磁盘加载历史 Session（幂等）。 */
  static ensureHistoryLoaded(): void {
    if (AppLogStore.historyLoaded || !AppLogStore.logsDir) {
      return;
    }
    AppLogStore.historyLoaded = true;
    AppLogStore.loadHistorySessions();
  }

  private static scheduleFlush(): void {
    if (AppLogStore.flushScheduled) {
      return;
    }
    AppLogStore.flushScheduled = true;
    setTimeout(() => {
      AppLogStore.flushScheduled = false;
      AppLogStore.flushPending();
    }, AppLogStore.FLUSH_INTERVAL_MS);
  }

  /** 合并刷新：替换引用触发 UI 更新 + 批量写盘。 */
  private static flushPending(): void {
    const sessions = AppStorage.get<LogSession[]>(SESSIONS_KEY);
    if (sessions) {
      const active = sessions.find(s => s.endTime === null);
      if (active && AppLogStore.pendingUiDirty) {
        // 替换 logs 引用 → @Track logs 变化 → @ObjectLink SessionCard 刷新计数
        active.logs = [...active.logs];
      }
      if (AppLogStore.pendingUiDirty) {
        // 替换 sessions 数组引用 → @StorageLink LogPage 感知列表更新
        AppStorage.setOrCreate<LogSession[]>(SESSIONS_KEY, [...sessions]);
      }
    }
    AppLogStore.pendingUiDirty = false;

    if (AppLogStore.pendingLines.length > 0 && AppLogStore.currentFile) {
      const chunk = AppLogStore.pendingLines.join('');
      AppLogStore.pendingLines = [];
      try {
        fs.writeSync(AppLogStore.currentFile.fd, chunk);
      } catch (e) {
        hilog.error(0xFF00, 'AppLogStore', 'flushPending write failed: %{public}s', JSON.stringify(e));
      }
    } else {
      AppLogStore.pendingLines = [];
    }
  }

  /**
   * 删除指定 Session，同时删除关联的磁盘日志文件（若存在）。
   */
  static deleteSession(id: string): void {
    const sessions = AppStorage.get<LogSession[]>(SESSIONS_KEY) ?? [];
    const session = sessions.find(s => s.id === id);
    if (session && session.filePath) {
      AppLogStore.safeUnlink(session.filePath);
    }
    AppStorage.setOrCreate<LogSession[]>(
      SESSIONS_KEY,
      sessions.filter(s => s.id !== id)
    );
  }

  /**
   * 获取指定 Session 的日志快照（用于文件导出）。
   */
  static getSessionSnapshot(id: string): LogData[] {
    const sessions = AppStorage.get<LogSession[]>(SESSIONS_KEY) ?? [];
    const session = sessions.find(s => s.id === id);
    return session ? [...session.logs] : [];
  }

  /** 清空所有 Session，同时删除所有磁盘日志文件。 */
  static clear(): void {
    try {
      if (AppLogStore.logsDir && fs.accessSync(AppLogStore.logsDir)) {
        const files = fs.listFileSync(AppLogStore.logsDir);
        for (const f of files) {
          if (f.startsWith(LOG_FILE_PREFIX) && f.endsWith(LOG_FILE_SUFFIX)) {
            AppLogStore.safeUnlink(AppLogStore.logsDir + '/' + f);
          }
        }
      }
    } catch (e) {
      // 忽略清理错误
    }
    AppLogStore.closeCurrentFile();
    AppStorage.setOrCreate<LogSession[]>(SESSIONS_KEY, []);
  }

  // ─── 私有辅助 ──────────────────────────────────────────────────────────────

  /** 确保日志目录存在 */
  private static ensureLogsDir(): void {
    if (!AppLogStore.logsDir) {
      return;
    }
    try {
      if (!fs.accessSync(AppLogStore.logsDir)) {
        fs.mkdirSync(AppLogStore.logsDir, true);
      }
    } catch (e) {
      // 忽略创建目录错误
    }
  }

  /** 扫描日志目录，加载历史 Session */
  private static loadHistorySessions(): void {
    if (!AppLogStore.logsDir) {
      return;
    }
    try {
      if (!fs.accessSync(AppLogStore.logsDir)) {
        return;
      }
      const files = fs.listFileSync(AppLogStore.logsDir);
      const logFiles = files
        .filter(f => f.startsWith(LOG_FILE_PREFIX) && f.endsWith(LOG_FILE_SUFFIX))
        .sort(); // 按文件名排序（时间顺序）

      hilog.info(0xFF00, 'AppLogStore', 'loadHistorySessions: found %{public}d log files in %{public}s', logFiles.length, AppLogStore.logsDir);

      const sessions = AppStorage.get<LogSession[]>(SESSIONS_KEY) ?? [];
      for (const fileName of logFiles) {
        const filePath = AppLogStore.logsDir + '/' + fileName;
        const session = AppLogStore.parseLogFile(filePath, fileName);
        // 延迟加载时当前活跃 Session 的文件已在磁盘上，按 id 去重避免重复会话
        if (session && sessions.some(s => s.id === session.id)) {
          continue;
        }
        if (session && session.logs.length > 0) {
          sessions.push(session);
          hilog.info(0xFF00, 'AppLogStore', 'loadHistorySessions: loaded session %{public}s with %{public}d logs', session.id, session.logs.length);
        } else {
          hilog.warn(0xFF00, 'AppLogStore', 'loadHistorySessions: deleting empty/invalid file %{public}s', fileName);
          AppLogStore.safeUnlink(filePath);
        }
      }

      // 限制 Session 数量，超出时删除最旧的文件
      if (sessions.length > MAX_SESSION_COUNT) {
        const toRemove = sessions.splice(0, sessions.length - MAX_SESSION_COUNT);
        for (const s of toRemove) {
          if (s.filePath) {
            AppLogStore.safeUnlink(s.filePath);
          }
        }
      }

      // 使用新数组引用触发 @StorageLink 刷新
      AppStorage.setOrCreate<LogSession[]>(SESSIONS_KEY, [...sessions]);
      hilog.info(0xFF00, 'AppLogStore', 'loadHistorySessions: total %{public}d sessions in memory', sessions.length);
    } catch (e) {
      hilog.error(0xFF00, 'AppLogStore', 'loadHistorySessions failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 解析单个日志文件为 LogSession */
  private static parseLogFile(filePath: string, fileName: string): LogSession | null {
    try {
      // 从文件名解析时间戳：yourpipe_YYYY-MM-DD_HH-mm-ss.log
      const match = fileName.match(
        new RegExp(`^${LOG_FILE_PREFIX}(\\d{4})-(\\d{2})-(\\d{2})_(\\d{2})-(\\d{2})-(\\d{2})${LOG_FILE_SUFFIX.replace('.', '\\.')}$`)
      );
      let startTime = Date.now();
      let id = Date.now().toString();
      if (match) {
        const year = match[1];
        const month = match[2];
        const day = match[3];
        const hour = match[4];
        const minute = match[5];
        const second = match[6];
        const timeStr = `${year}-${month}-${day}T${hour}:${minute}:${second}`;
        const parsed = new Date(timeStr).getTime();
        if (!isNaN(parsed)) {
          startTime = parsed;
          id = startTime.toString();
        }
      }

      const content = fs.readTextSync(filePath);
      const lines = content.split('\n').filter(l => l.trim());
      const logs: LogData[] = [];
      for (const line of lines) {
        try {
          const data = JSON.parse(line) as LogData;
          logs.push(data);
        } catch {
          // 忽略解析失败的行
        }
      }

      // 文件中是正序（旧在前），内存中需要倒序（新在前）
      logs.reverse();

      const session = new LogSession(id, startTime, filePath);
      session.logs = logs;
      // 使用文件修改时间作为结束时间
      try {
        const stat = fs.statSync(filePath);
        session.endTime = stat.mtime;
      } catch {
        session.endTime = startTime;
      }
      return session;
    } catch (e) {
      return null;
    }
  }

  /** 封存所有未关闭的 Session */
  private static sealActiveSessions(): void {
    const sessions = AppStorage.get<LogSession[]>(SESSIONS_KEY) ?? [];
    let changed = false;
    for (const s of sessions) {
      if (s.endTime === null) {
        s.endTime = Date.now(); // @Track endTime 变化 → @ObjectLink 刷新状态
        changed = true;
      }
    }
    if (changed) {
      AppStorage.setOrCreate<LogSession[]>(SESSIONS_KEY, [...sessions]);
    }
    // 先把缓冲中的日志批量落盘，再关闭文件，避免停录丢尾部。
    AppLogStore.flushPending();
    AppLogStore.closeCurrentFile();
  }

  /** 创建新 Session 并插入列表头部，超出上限时丢弃最旧 */
  private static createNewSession(): void {
    const sessions = AppStorage.get<LogSession[]>(SESSIONS_KEY) ?? [];
    const now = new Date();
    const id = now.getTime().toString();
    const filePath = AppLogStore.buildLogFilePath(now);
    const newSession = new LogSession(id, now.getTime(), filePath);

    // 打开新日志文件
    AppLogStore.openLogFile(filePath);
    AppLogStore.currentSessionId = id;

    const updated = [newSession, ...sessions];
    if (updated.length > MAX_SESSION_COUNT) {
      const removed = updated.splice(MAX_SESSION_COUNT);
      for (const s of removed) {
        if (s.filePath) {
          AppLogStore.safeUnlink(s.filePath);
        }
      }
    }
    AppStorage.setOrCreate<LogSession[]>(SESSIONS_KEY, updated);

    // 清理过期历史文件
    AppLogStore.cleanupOldFiles();
  }

  /** 生成日志文件路径 */
  private static buildLogFilePath(date: Date): string {
    const pad = (n: number) => String(n).padStart(2, '0');
    const ts = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}_${pad(date.getHours())}-${pad(date.getMinutes())}-${pad(date.getSeconds())}`;
    return AppLogStore.logsDir + '/' + LOG_FILE_PREFIX + ts + LOG_FILE_SUFFIX;
  }

  /** 打开日志文件（追加模式） */
  private static openLogFile(filePath: string): void {
    AppLogStore.closeCurrentFile();
    if (!filePath) {
      return;
    }
    try {
      AppLogStore.currentFile = fs.openSync(filePath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      hilog.info(0xFF00, 'AppLogStore', 'openLogFile OK: %{public}s', filePath);
    } catch (e) {
      AppLogStore.currentFile = null;
      hilog.error(0xFF00, 'AppLogStore', 'openLogFile failed: %{public}s, err=%{public}s', filePath, JSON.stringify(e));
    }
  }

  /** 关闭当前日志文件 */
  private static closeCurrentFile(): void {
    if (AppLogStore.currentFile) {
      try {
        fs.closeSync(AppLogStore.currentFile);
        hilog.info(0xFF00, 'AppLogStore', 'closeCurrentFile OK');
      } catch (e) {
        hilog.error(0xFF00, 'AppLogStore', 'closeCurrentFile failed: %{public}s', JSON.stringify(e));
      }
      AppLogStore.currentFile = null;
      AppLogStore.currentSessionId = '';
    }
  }

  /** 安全删除文件 */
  private static safeUnlink(filePath: string): void {
    try {
      if (fs.accessSync(filePath)) {
        fs.unlinkSync(filePath);
      }
    } catch (e) {
      // 忽略删除错误
    }
  }

  /** 清理超出 MAX_HISTORY_FILES 的旧日志文件 */
  private static cleanupOldFiles(): void {
    if (!AppLogStore.logsDir) {
      return;
    }
    try {
      if (!fs.accessSync(AppLogStore.logsDir)) {
        return;
      }
      const files = fs.listFileSync(AppLogStore.logsDir);
      const logFiles = files
        .filter(f => f.startsWith(LOG_FILE_PREFIX) && f.endsWith(LOG_FILE_SUFFIX))
        .sort();

      if (logFiles.length > MAX_HISTORY_FILES) {
        const toDelete = logFiles.slice(0, logFiles.length - MAX_HISTORY_FILES);
        for (const f of toDelete) {
          AppLogStore.safeUnlink(AppLogStore.logsDir + '/' + f);
        }
      }
    } catch (e) {
      // 忽略清理错误
    }
  }
}
