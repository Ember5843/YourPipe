import { VideoItem } from 'youtube_core';

interface LocalAppEntry {
  video: VideoItem;
  keywords: string[];
  summary: string;
}

class RankedVideoItem {
  score: number;
  item: VideoItem;

  constructor(score: number, item: VideoItem) {
    this.score = score;
    this.item = item;
  }
}

const LOCAL_APP_ENTRIES: LocalAppEntry[] = [
  {
    video: new VideoItem(
      1,
      'org.xbgroup.clashboxb',
      'ClashBox 代理工具',
      'HarmonyOS NEXT 示例',
      '版本 1.5.3',
      '',
      false,
      '#2F3B52',
      'org.xbgroup',
      '',
      '',
      ''
    ),
    summary: '代理软件，基于 Mihomo(ClashMeta) 内核，支持多设备。',
    keywords: ['clash', 'proxy', 'vpn', '代理', 'harmonyos next', 'openharmony', 'mihomo']
  },
  {
    video: new VideoItem(
      2,
      'com.huawei.videoapplication',
      '多设备长视频界面',
      'HarmonyOS Codelab',
      '自适应/响应式布局示例',
      '',
      false,
      '#B73A2C',
      'com.huawei',
      '',
      '',
      ''
    ),
    summary: '多端适配的长视频页面，支持折叠屏/平板/2in1。',
    keywords: ['长视频', '自适应', '响应式', '多设备', 'codelab', 'video']
  },
  {
    video: new VideoItem(
      3,
      'com.example.scrollcellingdemo',
      '商品页面刷新与展示',
      'HarmonyOS 示例',
      'Refresh/Scroll 组件',
      '',
      false,
      '#1D6FA5',
      'com.example',
      '',
      '',
      ''
    ),
    summary: '商品列表的下拉刷新/上拉加载与吸顶效果。',
    keywords: ['商品', '刷新', '滚动', 'scroll', 'refresh', '购物']
  },
  {
    video: new VideoItem(
      4,
      'net.openvally.videoplay',
      'AVPlayer 视频播放',
      'HarmonyOS 示例',
      '本地/网络视频播放',
      '',
      false,
      '#2E7D32',
      'net.openvally',
      '',
      '',
      ''
    ),
    summary: 'AVPlayer 播放、倍速、进度跳转与切换视频。',
    keywords: ['avplayer', '视频播放', '倍速', 'media', 'playback']
  },
  {
    video: new VideoItem(
      5,
      'com.example.yourtube',
      'Yourtube 客户端',
      '本地演示',
      '搜索/订阅/收藏',
      '',
      false,
      '#D32F2F',
      'com.example',
      '',
      '',
      ''
    ),
    summary: '支持搜索、订阅、收藏与播放页演示。',
    keywords: ['yourtube', '搜索', '订阅', '收藏', '播放器']
  }
];

function normalize(input: string): string {
  return input.trim().toLowerCase();
}

export function searchLocalApps(query: string): VideoItem[] {
  const keyword = normalize(query);
  if (!keyword) {
    return [];
  }
  const matches: RankedVideoItem[] = [];
  LOCAL_APP_ENTRIES.forEach((entry) => {
    const title = normalize(entry.video.title);
    const author = normalize(entry.video.author);
    const view = normalize(entry.video.viewCount);
    const summary = normalize(entry.summary);
    const keywords = entry.keywords.map((value) => normalize(value));
    let score = 0;
    if (title.includes(keyword)) score += 4;
    if (author.includes(keyword)) score += 2;
    if (view.includes(keyword)) score += 1;
    if (summary.includes(keyword)) score += 2;
    if (keywords.some((value) => value.includes(keyword))) score += 3;
    if (score > 0) {
      matches.push(new RankedVideoItem(score, entry.video));
    }
  });
  return matches
    .sort((a, b) => b.score - a.score)
    .map((entry) => entry.item);
}

export function suggestLocalApps(query: string, limit: number): string[] {
  const keyword = normalize(query);
  if (!keyword) {
    return [];
  }
  const pool = new Set<string>();
  LOCAL_APP_ENTRIES.forEach((entry) => {
    [entry.video.title, entry.video.author, entry.summary, ...entry.keywords].forEach((value) => {
      const normalized = normalize(value);
      if (normalized.includes(keyword)) {
        pool.add(value);
      }
    });
  });
  return Array.from(pool).slice(0, Math.max(0, limit));
}
