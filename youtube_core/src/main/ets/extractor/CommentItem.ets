/**
 * 评论条目数据模型 (参考 NewPipe: org.schabi.newpipe.extractor.comments.CommentInfoItem)
 */
export interface CommentItem {
  id: string;                    // 评论唯一标识
  commentId: string;             // YouTube 内部 ID
  videoId: string;               // 所属视频 ID
  authorName: string;            // 作者名称
  authorAvatarUrl: string;       // 作者头像 URL
  authorThumbnailColor: string;  // 头像占位颜色
  authorExternalChannelId: string; // 作者频道 ID
  commentText: string;           // 评论内容
  publishedTimeText: string;     // 发布时间 (如 "2小时前")
  likeCount: number;             // 点赞数
  replyCount: number;            // 回复总数
  isHeartedByAuthor: boolean;    // 是否被作者点心
  isPinned: boolean;             // 是否置顶
  authorIsVerified?: boolean;     // 作者是否经过验证
  authorIsCreator?: boolean;      // 作者是否是频道主
  hasCreatorReply?: boolean;     // 是否有创作者回复
  replyContinuation: string;     // 接续回复的 token
}

/**
 * 评论响应结果
 */
export interface CommentResponse {
  items: CommentItem[];          // 评论列表
  nextPageToken: string | null;  // 下一页加载 token
  commentCount?: number;         // 评论总数
}
