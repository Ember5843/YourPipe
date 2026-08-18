import { http } from '@kit.NetworkKit';
import { YTCoreLogger } from '../common/YTCoreLogger';
import {
  fixThumbnailUrl,
  getTextFromObject,
  getNestedValue,
  parseMixedNumber
} from '../common/YoutubeParsingHelper';
import { CommentItem, CommentResponse } from './CommentItem';

const logger = YTCoreLogger.getInstance('CommentsExtractor');

/**
 * CommentsExtractor 需要的最小后端面（由 YouTubeExtractor 实现）。
 * 窄接口避免 CommentsExtractor ⇄ YouTubeExtractor 循环依赖。
 */
export interface CommentsBackend {
  /** WEB /next 首访（取视频页元数据，用于定位评论区 continuation token） */
  getInnerTubeNextResponse(videoId: string): Promise<Record<string, Object>>;
  /** 带 continuation 的 WEB /next 翻页请求，返回原始 HTTP 响应 */
  postNextContinuation(continuation: string): Promise<http.HttpResponse>;
}

/**
 * 评论区提取（首屏 token 定位、翻页、回复、commentRenderer/commentViewModel 解析）。
 * 从 YouTubeExtractor 拆出；解析路径与 NewPipe/PipePipe 对齐（取最后一个 endpoint）。
 */
export class CommentsExtractor {
  private backend: CommentsBackend;

  constructor(backend: CommentsBackend) {
    this.backend = backend;
  }

  async fetchComments(videoId: string, nextPageToken: string | null = null): Promise<CommentResponse> {
    logger.debug(`[Comments] fetchComments for videoId: ${videoId}, token: ${nextPageToken ? 'provided' : 'none'}`);

    let continuation = nextPageToken;

    if (!continuation) {
      try {
        const nextResponse = await this.backend.getInnerTubeNextResponse(videoId);
        continuation = this.findInitialCommentsToken(nextResponse);
        if (!continuation) {
          logger.warn(`[Comments] No initial comments token found for videoId: ${videoId}`);
          return { items: [], nextPageToken: null, commentCount: 0 };
        }
      } catch (e) {
        const error = e as Error;
        logger.error(`[Comments] Initial token fetch failed: ${error.message}`);
        throw error;
      }
    }

    logger.debug(`[Comments] Fetching with WEB client...`);

    try {
      const response: http.HttpResponse = await this.backend.postNextContinuation(continuation);

      if (response.responseCode === 200) {
        const ajaxJson = JSON.parse(response.result as string) as Record<string, Object>;
        const commentResponse = this.parseCommentsResponse(ajaxJson, videoId);
        logger.info(`[Comments] Successfully extracted ${commentResponse.items.length} items`);
        return commentResponse;
      } else {
        logger.error(`[Comments] Request failed with ${response.responseCode}`);
      }
    } catch (e) {
      const error = e as Error;
      logger.error(`[Comments] Fetch error: ${error.message}`);
    }

    return { items: [], nextPageToken: null, commentCount: 0 };
  }

  async fetchCommentReplies(replyContinuation: string): Promise<CommentResponse> {
    logger.debug(`[Comments] fetchCommentReplies for token: ${replyContinuation}`);

    try {
      const response: http.HttpResponse = await this.backend.postNextContinuation(replyContinuation);

      if (response.responseCode === 200) {
        const ajaxJson = JSON.parse(response.result as string) as Record<string, Object>;
        return this.parseCommentsResponse(ajaxJson, '');
      }
    } catch (e) {
      const error = e as Error;
      logger.warn(`[Comments] Reply fetch error: ${error.message}`);
    }

    return { items: [], nextPageToken: null, commentCount: 0 };
  }

  private findInitialCommentsToken(nextResponse: Record<string, Object>): string | null {
    logger.debug(`[Comments] Extracting initial token from next response`);
    try {
      const contents = getNestedValue(nextResponse, 'contents.twoColumnWatchNextResults.results.results.contents') as Array<Object>;
      if (!contents) {
        logger.warn(`[Comments] contents path not found in nextResponse`);
        return null;
      }

      for (const item of contents) {
        const itemSection = (item as Record<string, Object>)['itemSectionRenderer'] as Record<string, Object>;
        if (itemSection && (itemSection['targetId'] === 'comments-section' || itemSection['sectionIdentifier'] === 'comment-item-section')) {
          const sectionContents = itemSection['contents'] as Array<Object>;
          if (sectionContents && sectionContents.length > 0) {
            const firstItem = sectionContents[0] as Record<string, Object>;
            let token = getNestedValue(firstItem, 'continuationItemRenderer.continuationEndpoint.continuationCommand.token') as string;

            if (!token) {
              const lastItem = sectionContents[sectionContents.length - 1] as Record<string, Object>;
              token = getNestedValue(lastItem, 'continuationItemRenderer.continuationEndpoint.continuationCommand.token') as string;
            }

            if (token) {
              logger.debug(`[Comments] Successfully found continuation token: ${token}`);
              return token;
            }
          }
        }
      }
    } catch (e) {
      logger.error('[Comments] findInitialCommentsToken failed:', e);
    }
    return null;
  }

  private parseCommentsResponse(ajaxJson: Record<string, Object>, videoId: string): CommentResponse {
    const items: CommentItem[] = [];
    let nextPageToken: string | null = null;
    let commentCount = 0;

    try {
      const endpoints = ajaxJson['onResponseReceivedEndpoints'] as Array<Object>;
      if (!endpoints || endpoints.length === 0) {
        logger.warn(`[Comments] No onResponseReceivedEndpoints found.`);
        return { items: [], nextPageToken: null, commentCount: 0 };
      }

      const mutations = getNestedValue(ajaxJson, 'frameworkUpdates.entityBatchUpdate.mutations') as Array<Object>;

      // NewPipe strictly takes the last endpoint for comments
      const epObj = endpoints[endpoints.length - 1] as Record<string, Object>;

      let continuationItems = (getNestedValue(epObj, 'reloadContinuationItemsCommand.continuationItems') ||
                               getNestedValue(epObj, 'appendContinuationItemsAction.continuationItems')) as Array<Object>;

      if (!continuationItems) {
        // Alternative paths
        continuationItems = (getNestedValue(epObj, 'sectionListRenderer.contents') ||
                             getNestedValue(epObj, 'itemSectionRenderer.contents')) as Array<Object>;
      }

      if (continuationItems) {
        logger.debug(`[Comments] Found ${continuationItems.length} items in the last endpoint`);

        for (const item of continuationItems) {
          const itemObj = item as Record<string, Object>;

          if (itemObj['commentThreadRenderer']) {
            const comment = this.parseCommentThread(itemObj['commentThreadRenderer'] as Record<string, Object>, mutations || [], videoId);
            if (comment) items.push(comment);
          } else if (itemObj['commentRenderer']) {
            const comment = this.parseCommentRenderer(itemObj['commentRenderer'] as Record<string, Object>, mutations || [], videoId);
            if (comment) items.push(comment);
          } else if (itemObj['commentViewModel']) {
            const comment = this.parseCommentViewModel(itemObj['commentViewModel'] as Record<string, Object>, null, mutations || [], videoId);
            if (comment) items.push(comment);
          } else if (itemObj['continuationItemRenderer']) {
            const contRenderer = itemObj['continuationItemRenderer'] as Record<string, Object>;
            nextPageToken = (getNestedValue(contRenderer, 'continuationEndpoint.continuationCommand.token') ||
                             getNestedValue(contRenderer, 'button.buttonRenderer.command.continuationCommand.token')) as string;
          } else if (itemObj['commentsHeaderRenderer']) {
            const countText = getNestedValue(itemObj, 'commentsHeaderRenderer.countText') as Record<string, Object>;
            commentCount = parseMixedNumber(getTextFromObject(countText));
          }
        }
      }

      if (items.length === 0) {
        logger.warn(`[Comments] Parsed 0 items. Endpoint keys: ${Object.keys(epObj).join('|')}`);
      }
    } catch (e) {
      const error = e as Error;
      logger.error('[Comments] parseCommentsResponse failed:', error.message);
    }

    return { items, nextPageToken, commentCount };
  }

  private parseCommentThread(renderer: Record<string, Object>, mutations: Array<Object>, videoId: string): CommentItem | null {
    const replies = renderer['replies'] as Record<string, Object>;
    const commentRepliesRenderer = replies ? (replies['commentRepliesRenderer'] as Record<string, Object>) : null;

    let item: CommentItem | null = null;
    if (renderer['commentViewModel']) {
      let vm = renderer['commentViewModel'] as Record<string, Object>;
      if (vm['commentViewModel']) {
        vm = vm['commentViewModel'] as Record<string, Object>;
      }
      item = this.parseCommentViewModel(vm, commentRepliesRenderer, mutations, videoId);
    } else if (renderer['comment']) {
      const commentObj = renderer['comment'] as Record<string, Object>;
      const commentRenderer = commentObj ? commentObj['commentRenderer'] as Record<string, Object> : null;
      if (commentRenderer) item = this.parseCommentRenderer(commentRenderer, mutations, videoId);
    }

    if (!item) return null;

    if (commentRepliesRenderer) {
      const replyContents = commentRepliesRenderer['contents'] as Array<Object>;
      if (replyContents && replyContents.length > 0) {
        const replyContItem = replyContents[0] as Record<string, Object>;
        const contRenderer = replyContItem['continuationItemRenderer'] as Record<string, Object>;
        if (contRenderer) {
          const token = getNestedValue(contRenderer, 'continuationEndpoint.continuationCommand.token') as string;
          item.replyContinuation = token || '';
        }
      }
    }
    return item;
  }

  private parseCommentRenderer(renderer: Record<string, Object>, mutations: Array<Object>, videoId: string): CommentItem | null {
    try {
      const commentId = renderer['commentId'] as string;
      const authorTextObj = renderer['authorText'] as Record<string, Object>;
      const authorName = authorTextObj ? getTextFromObject(authorTextObj) : '';
      const authorThumbnail = renderer['authorThumbnail'] as Record<string, Object>;
      const thumbnails = authorThumbnail ? authorThumbnail['thumbnails'] as Array<Record<string, string>> : null;
      const avatarUrl = fixThumbnailUrl((thumbnails && thumbnails.length > 0) ? thumbnails[0]['url'] : '');
      const contentTextObj = renderer['contentText'] as Record<string, Object>;
      const commentText = contentTextObj ? getTextFromObject(contentTextObj) : '';
      const publishedTimeTextObj = renderer['publishedTimeText'] as Record<string, Object>;
      const publishedTimeText = publishedTimeTextObj ? getTextFromObject(publishedTimeTextObj) : '';
      const voteCount = renderer['voteCount'] as Record<string, Object>;
      const likeCount = voteCount ? parseInt(getTextFromObject(voteCount).replace(/[^0-9]/g, '')) || 0 : 0;
      const replyCount = (renderer['replyCount'] as number) || 0;
      const authorEndpoint = renderer['authorEndpoint'] as Record<string, Object>;
      const authorExternalChannelId = authorEndpoint ? getNestedValue(authorEndpoint, 'browseEndpoint.browseId') as string : '';

      return {
        id: commentId || Math.random().toString(36).substring(2),
        commentId: commentId,
        videoId: videoId,
        authorName: authorName,
        authorAvatarUrl: avatarUrl,
        authorThumbnailColor: '#CCCCCC',
        authorExternalChannelId: authorExternalChannelId || '',
        commentText: commentText,
        publishedTimeText: publishedTimeText,
        likeCount: likeCount,
        replyCount: replyCount,
        isHeartedByAuthor: !!(renderer['actionButtons'] && getNestedValue(renderer, 'actionButtons.commentActionButtonsRenderer.creatorHeart')),
        isPinned: !!renderer['pinnedCommentBadge'],
        authorIsVerified: !!renderer['authorCommentBadge'],
        authorIsCreator: !!renderer['authorIsChannelOwner'],
        hasCreatorReply: false,
        replyContinuation: ''
      };
    } catch (e) {
      logger.debug(`[Comments] parseCommentRenderer skipped one item: ${(e as Error).message}`);
      return null;
    }
  }

  private parseCommentViewModel(viewModel: Record<string, Object>, commentRepliesRenderer: Record<string, Object> | null, mutations: Array<Object>, videoId: string): CommentItem | null {
    try {
      const commentKey = viewModel['commentKey'] as string;
      const toolbarStateKey = viewModel['toolbarStateKey'] as string;
      const commentPayload = this.getMutationPayloadFromEntityKey(mutations, commentKey);
      const toolbarPayload = this.getMutationPayloadFromEntityKey(mutations, toolbarStateKey);

      if (!commentPayload) return null;

      const commentEntity = commentPayload['commentEntityPayload'] as Record<string, Object>;
      const toolbarEntity = toolbarPayload ? toolbarPayload['engagementToolbarStateEntityPayload'] as Record<string, Object> : null;
      if (!commentEntity) return null;

      const properties = commentEntity['properties'] as Record<string, Object>;
      const author = commentEntity['author'] as Record<string, Object>;
      const toolbar = commentEntity['toolbar'] as Record<string, Object>;
      const avatar = commentEntity['avatar'] as Record<string, Object>;

      const commentId = properties['commentId'] as string || (viewModel['commentId'] as string);
      const authorName = author['displayName'] as string;
      const avatarSources = getNestedValue(avatar, 'image.sources') as Array<Record<string, string>>;
      let avatarUrl = (avatarSources && avatarSources.length > 0) ? avatarSources[0]['url'] : '';
      if (!avatarUrl) {
        // PipePipe fallback: some initial comment responses omit the avatar object
        // but provide the same image URL directly in the author payload.
        avatarUrl = (author['avatarThumbnailUrl'] as string) || '';
      }
      avatarUrl = fixThumbnailUrl(avatarUrl);
      const content = properties['content'] as Record<string, Object>;
      const commentText = content ? (content['content'] as string) : '';
      const publishedTimeText = properties['publishedTime'] as string;
      const likeCountStr = toolbar ? toolbar['likeCountNotliked'] as string : '';
      const likeCount = parseMixedNumber(likeCountStr);
      const replyCountStr = toolbar ? toolbar['replyCount'] as string : '';
      const replyCount = parseMixedNumber(replyCountStr);
      const channelId = author['channelId'] as string ||
                       (getNestedValue(author, 'channelCommand.innertubeCommand.browseEndpoint.browseId') as string) ||
                       (getNestedValue(avatar, 'endpoint.innertubeCommand.browseEndpoint.browseId') as string);

      return {
        id: commentId || Math.random().toString(36).substring(2),
        commentId: commentId,
        videoId: videoId,
        authorName: authorName,
        authorAvatarUrl: avatarUrl,
        authorThumbnailColor: '#CCCCCC',
        authorExternalChannelId: channelId || '',
        commentText: commentText,
        publishedTimeText: publishedTimeText,
        likeCount: likeCount,
        replyCount: replyCount,
        isHeartedByAuthor: toolbarEntity ? toolbarEntity['heartState'] === 'TOOLBAR_HEART_STATE_HEARTED' : false,
        isPinned: !!viewModel['pinnedText'],
        authorIsVerified: !!(author['isVerified'] || author['isArtist']),
        authorIsCreator: !!author['isCreator'],
        hasCreatorReply: !!(commentRepliesRenderer && commentRepliesRenderer['viewRepliesCreatorThumbnail']),
        replyContinuation: ''
      };
    } catch (e) {
      logger.debug(`[Comments] parseCommentViewModel skipped one item: ${(e as Error).message}`);
      return null;
    }
  }

  private getMutationPayloadFromEntityKey(mutations: Array<Object>, key: string): Record<string, Object> | null {
    if (!mutations || !key) return null;
    const mutation = mutations.find((m: Object) => {
      const mObj = m as Record<string, Object>;
      return mObj['entityKey'] === key;
    }) as Record<string, Object>;
    return mutation ? (mutation['payload'] as Record<string, Object>) : null;
  }
}
