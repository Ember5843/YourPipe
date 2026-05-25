import { i18n } from '@kit.LocalizationKit';
import { ContentCountry } from 'youtube_core';
import { Localization } from 'youtube_core';
import { fetchBrowsePage } from 'youtube_core';

export class ChannelDetails {
  description: string;
  bannerUrl: string;

  constructor(description: string = '', bannerUrl: string = '') {
    this.description = description;
    this.bannerUrl = bannerUrl;
  }
}

export class ChannelProfile {
  name: string;
  description: string;
  bannerUrl: string;
  avatarUrl: string;
  subscriberText: string;
  videoCountText: string;
  handle: string;

  constructor(
    name: string = '',
    description: string = '',
    bannerUrl: string = '',
    avatarUrl: string = '',
    subscriberText: string = '',
    videoCountText: string = '',
    handle: string = ''
  ) {
    this.name = name;
    this.description = description;
    this.bannerUrl = bannerUrl;
    this.avatarUrl = avatarUrl;
    this.subscriberText = subscriberText;
    this.videoCountText = videoCountText;
    this.handle = handle;
  }
}

class LocaleContext {
  localization: Localization;
  contentCountry: ContentCountry;

  constructor(localization: Localization, contentCountry: ContentCountry) {
    this.localization = localization;
    this.contentCountry = contentCountry;
  }
}

export class ChannelInfoService {
  private readonly VIDEOS_TAB_PARAMS: string = 'EgZ2aWRlb3PyBgQKAjoA';

  async fetchChannelDetails(channelId: string): Promise<ChannelDetails> {
    const trimmed = (channelId || '').trim();
    if (!trimmed) {
      return new ChannelDetails();
    }

    const localeContext = this.resolveLocale();
    const localization = localeContext.localization;
    const contentCountry = localeContext.contentCountry;
    const response = await fetchBrowsePage(localization, contentCountry, trimmed, this.VIDEOS_TAB_PARAMS);
    if (!response) {
      return new ChannelDetails();
    }
    const root = response as Record<string, Object>;
    const description = this.extractDescription(root);
    const bannerUrl = this.extractBannerUrl(root);
    return new ChannelDetails(description, bannerUrl);
  }

  async fetchChannelProfile(channelId: string): Promise<ChannelProfile> {
    const trimmed = (channelId || '').trim();
    if (!trimmed) {
      return new ChannelProfile();
    }
    const localeContext = this.resolveLocale();
    const localization = localeContext.localization;
    const contentCountry = localeContext.contentCountry;
    const response = await fetchBrowsePage(localization, contentCountry, trimmed, this.VIDEOS_TAB_PARAMS);
    if (!response) {
      return new ChannelProfile();
    }
    const root = response as Record<string, Object>;
    const name = this.extractChannelName(root);
    const description = this.extractDescription(root);
    const bannerUrl = this.extractBannerUrl(root);
    const avatarUrl = this.extractAvatarUrl(root);
    const subscriberText = this.extractSubscriberText(root);
    const videoCountText = this.extractVideoCountText(root);
    const handle = this.extractHandle(root);
    return new ChannelProfile(name, description, bannerUrl, avatarUrl, subscriberText, videoCountText, handle);
  }

  private resolveLocale(): LocaleContext {
    const language: string = i18n.System.getSystemLanguage();
    const localization = new Localization(language || Localization.DEFAULT.getLanguageCode(), 'GB');
    const contentCountry = new ContentCountry('GB');
    return new LocaleContext(localization, contentCountry);
  }

  private extractDescription(root: Record<string, Object>): string {
    const metadata = this.asRecord(root['metadata']);
    const channelMetadata = this.asRecord(metadata?.['channelMetadataRenderer']);
    const desc = this.asString(channelMetadata?.['description']);
    if (desc) {
      return desc;
    }

    const header = this.asRecord(root['header']);
    const interactive = this.asRecord(header?.['interactiveTabbedHeaderRenderer']);
    const headerDesc = interactive ? this.readText(interactive['description']) : '';
    return headerDesc || '';
  }

  private extractBannerUrl(root: Record<string, Object>): string {
    const header = this.asRecord(root['header']);
    if (!header) {
      return '';
    }

    const pageHeader = this.asRecord(header['pageHeaderRenderer']);
    const pageHeaderContent = this.asRecord(pageHeader?.['content']);
    const pageHeaderViewModel = this.asRecord(pageHeaderContent?.['pageHeaderViewModel']);
    const banner = this.asRecord(pageHeaderViewModel?.['banner']);
    const imageBanner = this.asRecord(banner?.['imageBannerViewModel']);
    const image = this.asRecord(imageBanner?.['image']);
    const sources = this.asArray(image?.['sources']);
    const pageBanner = this.pickLargestImageUrl(sources);
    if (pageBanner) {
      return this.normalizeUrl(pageBanner);
    }

    const renderers = ['c4TabbedHeaderRenderer', 'interactiveTabbedHeaderRenderer', 'carouselHeaderRenderer'];
    for (let i = 0; i < renderers.length; i++) {
      const renderer = this.asRecord(header[renderers[i]]);
      const thumbnails = this.asArray(this.asRecord(renderer?.['banner'])?.['thumbnails']);
      const banner = this.pickLargestImageUrl(thumbnails);
      if (banner) {
        return this.normalizeUrl(banner);
      }
    }
    return '';
  }

  private extractChannelName(root: Record<string, Object>): string {
    const metadata = this.asRecord(root['metadata']);
    const channelMetadata = this.asRecord(metadata?.['channelMetadataRenderer']);
    const title = this.asString(channelMetadata?.['title']);
    if (title) {
      return title;
    }
    const header = this.asRecord(root['header']);
    const c4 = this.asRecord(header?.['c4TabbedHeaderRenderer']);
    const c4Title = c4 ? this.readText(c4['title']) : '';
    return c4Title || '';
  }

  private extractHandle(root: Record<string, Object>): string {
    const metadata = this.asRecord(root['metadata']);
    const channelMetadata = this.asRecord(metadata?.['channelMetadataRenderer']);
    const handle = this.asString(channelMetadata?.['vanityChannelUrl']);
    if (handle) {
      return `@${handle}`;
    }
    const header = this.asRecord(root['header']);
    const c4 = this.asRecord(header?.['c4TabbedHeaderRenderer']);
    const c4Handle = c4 ? this.readText(c4['vanityChannelUrl']) : '';
    return c4Handle ? `@${c4Handle}` : '';
  }

  private extractAvatarUrl(root: Record<string, Object>): string {
    // 从header中提取
    const header = this.asRecord(root['header']);
    if (header) {
      // 尝试从c4TabbedHeaderRenderer提取
      const c4 = this.asRecord(header['c4TabbedHeaderRenderer']);
      if (c4) {
        const avatar = this.asRecord(c4['avatar']);
        const thumbnails = this.asArray(avatar?.['thumbnails']);
        const url = this.pickLargestImageUrl(thumbnails);
        if (url) {
          return this.normalizeUrl(url);
        }
      }
      
      // 尝试从interactiveTabbedHeaderRenderer提取
      const interactive = this.asRecord(header['interactiveTabbedHeaderRenderer']);
      if (interactive) {
        const boxArt = this.asRecord(interactive['boxArt']);
        const thumbnails = this.asArray(boxArt?.['thumbnails']);
        const url = this.pickLargestImageUrl(thumbnails);
        if (url) {
          return this.normalizeUrl(url);
        }
      }
      
      // 尝试从carouselHeaderRenderer提取
      const carousel = this.asRecord(header['carouselHeaderRenderer']);
      if (carousel) {
        const contents = this.asArray(carousel['contents']);
        if (contents && contents.length > 0) {
          const firstItem = this.asRecord(contents[0]);
          if (firstItem) {
            const topicDetails = this.asRecord(firstItem['topicChannelDetailsRenderer']);
            if (topicDetails) {
              const avatar = this.asRecord(topicDetails['avatar']);
              const thumbnails = this.asArray(avatar?.['thumbnails']);
              const url = this.pickLargestImageUrl(thumbnails);
              if (url) {
                return this.normalizeUrl(url);
              }
            }
          }
        }
      }
      
      // 尝试从pageHeaderRenderer提取
      const pageHeader = this.asRecord(header['pageHeaderRenderer']);
      if (pageHeader) {
        const pageHeaderContent = this.asRecord(pageHeader['content']);
        const pageHeaderViewModel = this.asRecord(pageHeaderContent?.['pageHeaderViewModel']);
        if (pageHeaderViewModel) {
          const avatar = this.asRecord(pageHeaderViewModel['avatar']);
          if (avatar) {
            const image = this.asRecord(avatar['image']);
            const sources = this.asArray(image?.['sources']);
            const url = this.pickLargestImageUrl(sources);
            if (url) {
              return this.normalizeUrl(url);
            }
          }
          
          // 尝试从contentPreviewImageViewModel提取
          const image = this.asRecord(pageHeaderViewModel['image']);
          if (image) {
            const contentPreview = this.asRecord(image['contentPreviewImageViewModel']);
            if (contentPreview) {
              const previewImage = this.asRecord(contentPreview['image']);
              const sources = this.asArray(previewImage?.['sources']);
              const url = this.pickLargestImageUrl(sources);
              if (url) {
                return this.normalizeUrl(url);
              }
            }
          }
        }
      }
    }
    
    // 从metadata中提取
    const metadata = this.asRecord(root['metadata']);
    if (metadata) {
      const channelMetadata = this.asRecord(metadata['channelMetadataRenderer']);
      if (channelMetadata) {
        const avatar = this.asRecord(channelMetadata['avatar']);
        if (avatar) {
          const thumbnails = this.asArray(avatar['thumbnails']);
          const url = this.pickLargestImageUrl(thumbnails);
          if (url) {
            return this.normalizeUrl(url);
          }
        }
      }
    }
    
    return '';
  }

  private extractSubscriberText(root: Record<string, Object>): string {
    // 严格按照NewPipeExtractor的getSubscriberCountFromPageChannelHeader逻辑
    const header = this.asRecord(root['header']);
    if (header) {
      const pageHeader = this.asRecord(header['pageHeaderRenderer']);
      if (pageHeader) {
        const pageHeaderContent = this.asRecord(pageHeader['content']);
        if (pageHeaderContent) {
          const pageHeaderViewModel = this.asRecord(pageHeaderContent['pageHeaderViewModel']);
          if (pageHeaderViewModel) {
            const metadata = this.asRecord(pageHeaderViewModel['metadata']);
            if (metadata) {
              const contentMetadata = this.asRecord(metadata['contentMetadataViewModel']);
              if (contentMetadata) {
                const metadataRows = this.asArray(contentMetadata['metadataRows']);
                if (metadataRows && metadataRows.length > 0) {
                  // 从最后一行元数据中提取订阅数
                  const lastRow = this.asRecord(metadataRows[metadataRows.length - 1]);
                  if (lastRow) {
                    const metadataParts = this.asArray(lastRow['metadataParts']);
                    if (metadataParts && metadataParts.length >= 2) {
                      // 订阅数在第一个位置（按照NewPipeExtractor的逻辑）
                      const subscriberCountPart = this.asRecord(metadataParts[0]);
                      if (subscriberCountPart) {
                        const text = this.readText(subscriberCountPart['text']);
                        if (text) {
                          return text;
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    
    return '';
  }

  private extractVideoCountText(root: Record<string, Object>): string {
    // 严格按照NewPipeExtractor的逻辑，从contentMetadataViewModel中获取视频数量
    const header = this.asRecord(root['header']);
    if (header) {
      const pageHeader = this.asRecord(header['pageHeaderRenderer']);
      if (pageHeader) {
        const pageHeaderContent = this.asRecord(pageHeader['content']);
        if (pageHeaderContent) {
          const pageHeaderViewModel = this.asRecord(pageHeaderContent['pageHeaderViewModel']);
          if (pageHeaderViewModel) {
            const metadata = this.asRecord(pageHeaderViewModel['metadata']);
            if (metadata) {
              const contentMetadata = this.asRecord(metadata['contentMetadataViewModel']);
              if (contentMetadata) {
                const metadataRows = this.asArray(contentMetadata['metadataRows']);
                if (metadataRows && metadataRows.length > 0) {
                  // 从最后一行元数据中提取视频数
                  const lastRow = this.asRecord(metadataRows[metadataRows.length - 1]);
                  if (lastRow) {
                    const metadataParts = this.asArray(lastRow['metadataParts']);
                    if (metadataParts && metadataParts.length >= 2) {
                      // 视频数在第二个位置（按照NewPipeExtractor的逻辑）
                      const videoCountPart = this.asRecord(metadataParts[1]);
                      if (videoCountPart) {
                        const text = this.readText(videoCountPart['text']);
                        if (text) {
                          return text;
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    
    return '';
  }

  private pickLargestImageUrl(list: Array<Object> | null): string {
    if (!list || list.length === 0) {
      return '';
    }
    let bestUrl: string = '';
    let bestArea: number = -1;
    list.forEach((item) => {
      const record = this.asRecord(item);
      const url = this.asString(record?.['url']);
      const width = this.asNumber(record?.['width']);
      const height = this.asNumber(record?.['height']);
      const area = (width > 0 && height > 0) ? width * height : -1;
      if (!url) {
        return;
      }
      if (area > bestArea) {
        bestArea = area;
        bestUrl = url;
      }
      if (bestArea < 0 && !bestUrl) {
        bestUrl = url;
      }
    });
    return bestUrl;
  }

  private normalizeUrl(url: string): string {
    const trimmed = (url || '').trim();
    if (!trimmed) {
      return '';
    }
    if (trimmed.startsWith('//')) {
      return `https:${trimmed}`;
    }
    return trimmed;
  }

  private readText(obj: Object | undefined): string {
    const record = this.asRecord(obj);
    if (!record) {
      return '';
    }
    const simpleText = this.asString(record['content']);
    return simpleText;

  }

  private asRecord(value: Object | undefined): Record<string, Object> | null {
    if (!value || typeof value !== 'object') {
      return null;
    }
    return value as Record<string, Object>;
  }

  private asArray(value: Object | undefined): Array<Object> | null {
    if (!Array.isArray(value)) {
      return null;
    }
    return value as Array<Object>;
  }

  private asString(value: Object | undefined): string {
    return typeof value === 'string' ? value : '';
  }

  private asNumber(value: Object | undefined): number {
    return typeof value === 'number' ? value : -1;
  }
}
