import { http } from '@kit.NetworkKit';
import { YTCoreLogger } from '../common/YTCoreLogger';
import {
  fixThumbnailUrl,
  getNestedValue,
  getTextFromObject,
  pickHighestThumbnailUrl
} from '../common/YoutubeParsingHelper';

const logger = YTCoreLogger.getInstance('LiveChatExtractor');

/** 单条直播聊天消息（只读）。 */
export interface LiveChatMessage {
  id: string;
  authorName: string;
  authorPhotoUrl: string;
  text: string;
  timestampMs: number;
  isPaid: boolean;
  amountText: string;
  isMember: boolean;
  isOwner: boolean;
  isModerator: boolean;
}

/** 一页直播聊天 + 下一次轮询的 continuation。 */
export interface LiveChatPage {
  available: boolean;
  ended: boolean;
  messages: LiveChatMessage[];
  continuation: string;
  timeoutMs: number;
}

/**
 * LiveChatExtractor 的最小后端面（YouTubeExtractor 实现）：
 * 首访 /next 取 conversationBar 里的 continuation，再 POST live_chat。
 */
export interface LiveChatBackend {
  getInnerTubeNextResponse(videoId: string): Promise<Record<string, Object>>;
  postLiveChatContinuation(continuation: string, playerOffsetMs: number): Promise<http.HttpResponse>;
}

const DEFAULT_TIMEOUT_MS: number = 5000;
const MIN_TIMEOUT_MS: number = 1000;
const MAX_TIMEOUT_MS: number = 15000;

/**
 * YouTube 直播聊天 / 实时评论（只读）。
 * 协议对齐 PipePipe `YoutubeBulletCommentsExtractor` 与 SmartTube
 * `LiveChatServiceInt`：
 * - 从 watch next 的 `conversationBar.liveChatRenderer.continuations[0]`
 *   取初始 continuation；
 * - 轮询 `youtubei/v1/live_chat/get_live_chat`，响应里带
 *   `timedContinuationData` / `invalidationContinuationData` 的 timeoutMs；
 * - 只解析聊天项（文本 / Super Chat / 会员），忽略系统提示与打赏 sticker。
 */
export class LiveChatExtractor {
  private backend: LiveChatBackend;

  constructor(backend: LiveChatBackend) {
    this.backend = backend;
  }

  /** 首访：没有直播聊天（点播 / 聊天关闭）时 available=false。 */
  async fetchInitial(videoId: string): Promise<LiveChatPage> {
    try {
      const next = await this.backend.getInnerTubeNextResponse(videoId);
      const continuation = LiveChatExtractor.findInitialContinuation(next);
      if (!continuation) {
        logger.info(`[LiveChat] no live chat continuation video=${videoId}`);
        return LiveChatExtractor.emptyPage(false, false);
      }
      const page = await this.fetchPage(continuation, -1);
      page.available = true;
      return page;
    } catch (e) {
      logger.warn(`[LiveChat] initial failed video=${videoId}: ${(e as Error).message || e}`);
      return LiveChatExtractor.emptyPage(false, false);
    }
  }

  /** 轮询一页；playerOffsetMs < 0 表示实时直播（非回放）。 */
  async fetchPage(continuation: string, playerOffsetMs: number): Promise<LiveChatPage> {
    const token = (continuation || '').trim();
    if (!token) {
      return LiveChatExtractor.emptyPage(true, true);
    }
    const response = await this.backend.postLiveChatContinuation(token, playerOffsetMs);
    if (response.responseCode !== 200) {
      throw new Error(`live chat HTTP ${response.responseCode}`);
    }
    const json = JSON.parse(response.result as string) as Record<string, Object>;
    return LiveChatExtractor.parsePage(json);
  }

  private static parsePage(json: Record<string, Object>): LiveChatPage {
    const chat = getNestedValue(json, 'continuationContents.liveChatContinuation') as Record<string, Object>;
    if (!chat) {
      return LiveChatExtractor.emptyPage(true, true);
    }
    const messages: LiveChatMessage[] = [];
    const actions = chat['actions'] as Array<Object>;
    if (actions && actions.length > 0) {
      for (let i = 0; i < actions.length; i++) {
        const item = LiveChatExtractor.chatItemOf(actions[i] as Record<string, Object>);
        if (!item) {
          continue;
        }
        const message = LiveChatExtractor.parseItem(item);
        if (message) {
          messages.push(message);
        }
      }
    }

    let nextContinuation = '';
    let timeoutMs = DEFAULT_TIMEOUT_MS;
    const continuations = chat['continuations'] as Array<Object>;
    if (continuations && continuations.length > 0) {
      const first = continuations[0] as Record<string, Object>;
      const data = (first['timedContinuationData'] || first['invalidationContinuationData']
        || first['reloadContinuationData']) as Record<string, Object>;
      if (data) {
        nextContinuation = (data['continuation'] as string) || '';
        const rawTimeout = data['timeoutMs'];
        const parsed = typeof rawTimeout === 'number' ? rawTimeout as number : Number(rawTimeout as string);
        if (Number.isFinite(parsed) && parsed > 0) {
          timeoutMs = Math.min(MAX_TIMEOUT_MS, Math.max(MIN_TIMEOUT_MS, parsed));
        }
      }
    }
    return {
      available: true,
      ended: nextContinuation.length === 0,
      messages,
      continuation: nextContinuation,
      timeoutMs
    };
  }

  /** live: addChatItemAction；replay: replayChatItemAction.actions[0]。 */
  private static chatItemOf(action: Record<string, Object>): Record<string, Object> | null {
    if (!action) {
      return null;
    }
    const add = action['addChatItemAction'] as Record<string, Object>;
    if (add) {
      return (add['item'] as Record<string, Object>) || null;
    }
    const replay = action['replayChatItemAction'] as Record<string, Object>;
    if (replay) {
      const replayActions = replay['actions'] as Array<Object>;
      if (replayActions && replayActions.length > 0) {
        const replayAdd = (replayActions[0] as Record<string, Object>)['addChatItemAction'] as Record<string, Object>;
        if (replayAdd) {
          return (replayAdd['item'] as Record<string, Object>) || null;
        }
      }
    }
    const banner = getNestedValue(action,
      'addBannerToLiveChatCommand.bannerRenderer.liveChatBannerRenderer.contents') as Record<string, Object>;
    return banner || null;
  }

  private static parseItem(item: Record<string, Object>): LiveChatMessage | null {
    const textRenderer = item['liveChatTextMessageRenderer'] as Record<string, Object>;
    const paidRenderer = item['liveChatPaidMessageRenderer'] as Record<string, Object>;
    const memberRenderer = item['liveChatMembershipItemRenderer'] as Record<string, Object>;
    const renderer = textRenderer || paidRenderer || memberRenderer;
    if (!renderer) {
      return null;
    }

    const id = (renderer['id'] as string) || `lc_${Date.now()}_${Math.random()}`;
    const authorName = getTextFromObject(renderer['authorName'] as Record<string, Object>);
    const text = LiveChatExtractor.messageText(renderer['message'] as Record<string, Object>);
    const photoNode = renderer['authorPhoto'] as Record<string, Object>;
    const photoCandidates = photoNode ? photoNode['thumbnails'] as Array<Record<string, Object>> : [];
    const authorPhotoUrl = fixThumbnailUrl(pickHighestThumbnailUrl(photoCandidates || []));
    const amountText = getTextFromObject(renderer['purchaseAmountText'] as Record<string, Object>);
    const timestampMs = LiveChatExtractor.timestampOf(renderer);

    let isOwner = false;
    let isModerator = false;
    let isMember = false;
    const badges = renderer['authorBadges'] as Array<Object>;
    if (badges && badges.length > 0) {
      for (let i = 0; i < badges.length; i++) {
        const badge = (badges[i] as Record<string, Object>)['liveChatAuthorBadgeRenderer'] as Record<string, Object>;
        if (!badge) {
          continue;
        }
        const iconType = (getNestedValue(badge, 'icon.iconType') as string) || '';
        if (iconType === 'OWNER') {
          isOwner = true;
        } else if (iconType === 'MODERATOR') {
          isModerator = true;
        } else if (iconType === 'MEMBER') {
          isMember = true;
        }
      }
    }

    return {
      id,
      authorName,
      authorPhotoUrl,
      text,
      timestampMs,
      isPaid: !!paidRenderer,
      amountText,
      isMember: isMember || !!memberRenderer,
      isOwner,
      isModerator
    };
  }

  /** message.runs 里的 emoji run 没有 text，只有 emoji.shortcuts。 */
  private static messageText(message: Record<string, Object> | undefined): string {
    if (!message) {
      return '';
    }
    if (message['simpleText']) {
      return message['simpleText'] as string;
    }
    const runs = message['runs'] as Array<Record<string, Object>>;
    if (!runs || runs.length === 0) {
      return '';
    }
    const parts: string[] = [];
    for (let i = 0; i < runs.length; i++) {
      const run = runs[i];
      const text = run['text'] as string;
      if (text) {
        parts.push(text);
        continue;
      }
      const emoji = run['emoji'] as Record<string, Object>;
      if (emoji) {
        const shortcuts = emoji['shortcuts'] as Array<string>;
        if (shortcuts && shortcuts.length > 0) {
          parts.push(shortcuts[0]);
        }
      }
    }
    return parts.join('');
  }

  private static timestampOf(renderer: Record<string, Object>): number {
    const usec = renderer['timestampUsec'];
    if (usec !== undefined && usec !== null) {
      const parsed = typeof usec === 'number' ? usec as number : Number(usec as string);
      if (Number.isFinite(parsed) && parsed > 0) {
        return Math.floor(parsed / 1000);
      }
    }
    const msec = renderer['timestampMs'];
    if (msec !== undefined && msec !== null) {
      const parsed = typeof msec === 'number' ? msec as number : Number(msec as string);
      if (Number.isFinite(parsed) && parsed > 0) {
        return parsed;
      }
    }
    return Date.now();
  }

  private static findInitialContinuation(next: Record<string, Object>): string {
    const renderer = getNestedValue(next,
      'contents.twoColumnWatchNextResults.conversationBar.liveChatRenderer') as Record<string, Object>;
    if (!renderer) {
      return '';
    }
    const continuations = renderer['continuations'] as Array<Object>;
    if (!continuations || continuations.length === 0) {
      return '';
    }
    const first = continuations[0] as Record<string, Object>;
    const reload = first['reloadContinuationData'] as Record<string, Object>;
    if (reload) {
      return (reload['continuation'] as string) || '';
    }
    const timed = first['timedContinuationData'] as Record<string, Object>;
    if (timed) {
      return (timed['continuation'] as string) || '';
    }
    const invalidation = first['invalidationContinuationData'] as Record<string, Object>;
    if (invalidation) {
      return (invalidation['continuation'] as string) || '';
    }
    return '';
  }

  private static emptyPage(available: boolean, ended: boolean): LiveChatPage {
    return {
      available,
      ended,
      messages: [],
      continuation: '',
      timeoutMs: DEFAULT_TIMEOUT_MS
    };
  }
}
