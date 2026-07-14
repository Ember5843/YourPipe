import { ContentCountry } from 'youtube_core';
import { Localization } from 'youtube_core';
import { fetchBrowsePage } from 'youtube_core';
import { SearchLocaleManager } from '../../common/SearchLocaleManager';

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
    // Align with SearchLocaleManager / feed services (not hard-coded en/GB).
    const bundle = SearchLocaleManager.getSearchLocaleBundle();
    return new LocaleContext(bundle.localization, bundle.contentCountry);
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
    const header = this.asRecord(root['header']);
    if (header) {
      // c4TabbedHeaderRenderer / interactiveTabbedHeaderRenderer
      const renderers = ['c4TabbedHeaderRenderer', 'interactiveTabbedHeaderRenderer', 'carouselHeaderRenderer'];
      for (let i = 0; i < renderers.length; i++) {
        const renderer = this.asRecord(header[renderers[i]]);
        if (renderer) {
          const subscriberCountText = this.asRecord(renderer['subscriberCountText']);
          const text = subscriberCountText ? this.readContent(subscriberCountText) : '';
          if (text) {
            return text;
          }
          const subtitle = this.asRecord(renderer['subtitle']);
          const subtitleText = subtitle ? this.readContent(subtitle) : '';
          if (subtitleText) {
            return subtitleText;
          }
        }
      }

      // pageHeaderRenderer (modern format) - follow PipePipe's getSubscriberCountFromPageChannelHeader
      const pageHeader = this.asRecord(header['pageHeaderRenderer']);
      if (pageHeader) {
        const pageHeaderContent = this.asRecord(pageHeader['content']);
        const pageHeaderViewModel = this.asRecord(pageHeaderContent?.['pageHeaderViewModel']);
        const metadata = this.asRecord(pageHeaderViewModel?.['metadata']);
        const contentMetadata = this.asRecord(metadata?.['contentMetadataViewModel']);
        const metadataRows = this.asArray(contentMetadata?.['metadataRows']);
        if (metadataRows) {
          // First pass: look for explicit "subscriber" keyword
          for (let r = 0; r < metadataRows.length; r++) {
            const row = this.asRecord(metadataRows[r]);
            const parts = this.asArray(row?.['metadataParts']);
            if (!parts) continue;
            for (let p = 0; p < parts.length; p++) {
              const part = this.asRecord(parts[p]);
              const text = this.asRecord(part?.['text']);
              const content = this.asString(text?.['content']);
              if (content && content.toLowerCase().includes('subscriber')) {
                return content;
              }
            }
          }

          // Second pass: use accessibilityLabel as fallback (localized responses)
          for (let r = 0; r < metadataRows.length; r++) {
            const row = this.asRecord(metadataRows[r]);
            const parts = this.asArray(row?.['metadataParts']);
            if (!parts || parts.length === 0) continue;

            if (parts.length > 1) {
              const firstPart = this.asRecord(parts[0]);
              if (firstPart && firstPart['accessibilityLabel']) {
                const text = this.asRecord(firstPart['text']);
                const content = this.asString(text?.['content']);
                if (content && !content.startsWith('@')) {
                  return content;
                }
              }
            } else {
              const part = this.asRecord(parts[0]);
              if (part && part['accessibilityLabel']) {
                const text = this.asRecord(part['text']);
                const content = this.asString(text?.['content']);
                if (content && !content.startsWith('@')) {
                  return content;
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
    const header = this.asRecord(root['header']);
    if (header) {
      // c4TabbedHeaderRenderer has a direct videoCountText
      const renderers = ['c4TabbedHeaderRenderer'];
      for (let i = 0; i < renderers.length; i++) {
        const renderer = this.asRecord(header[renderers[i]]);
        if (renderer) {
          const videoCountText = this.asRecord(renderer['videoCountText']);
          const text = videoCountText ? this.readContent(videoCountText) : '';
          if (text) {
            return text;
          }
        }
      }

      // pageHeaderRenderer (modern format) - scan all metadataRows
      const pageHeader = this.asRecord(header['pageHeaderRenderer']);
      if (pageHeader) {
        const pageHeaderContent = this.asRecord(pageHeader['content']);
        const pageHeaderViewModel = this.asRecord(pageHeaderContent?.['pageHeaderViewModel']);
        const metadata = this.asRecord(pageHeaderViewModel?.['metadata']);
        const contentMetadata = this.asRecord(metadata?.['contentMetadataViewModel']);
        const metadataRows = this.asArray(contentMetadata?.['metadataRows']);
        if (metadataRows) {
          // Look for explicit "video" keyword
          for (let r = 0; r < metadataRows.length; r++) {
            const row = this.asRecord(metadataRows[r]);
            const parts = this.asArray(row?.['metadataParts']);
            if (!parts) continue;
            for (let p = 0; p < parts.length; p++) {
              const part = this.asRecord(parts[p]);
              const text = this.asRecord(part?.['text']);
              const content = this.asString(text?.['content']);
              if (content && content.toLowerCase().includes('video')) {
                return content;
              }
            }
          }

          // Fallback: use accessibilityLabel, second part in multi-part rows
          for (let r = 0; r < metadataRows.length; r++) {
            const row = this.asRecord(metadataRows[r]);
            const parts = this.asArray(row?.['metadataParts']);
            if (!parts || parts.length < 2) continue;

            // The video count is typically the second part
            const videoPart = this.asRecord(parts[1]);
            if (videoPart && videoPart['accessibilityLabel']) {
              const text = this.asRecord(videoPart['text']);
              const content = this.asString(text?.['content']);
              if (content && !content.startsWith('@')) {
                return content;
              }
            }
          }
        }
      }
    }

    // Fallback: check metadata.channelMetadataRenderer (no video count available here)
    return '';
  }

  private pickLargestImageUrl(list: Array<Object> | null): string {
    if (!list || list.length === 0) {
      return '';
    }
    let bestUrl: string = '';
    let bestArea: number = -1;
    for (let i = 0; i < list.length; i++) {
      const record = this.asRecord(list[i]);
      const url = this.normalizeUrl(this.asString(record?.['url']));
      if (!url) {
        continue;
      }
      const width = this.asNumber(record?.['width']);
      const height = this.asNumber(record?.['height']);
      let area = 0;
      if (width > 0 && height > 0) {
        area = width * height;
      } else if (width > 0) {
        area = width * 1000;
      } else if (height > 0) {
        area = height * 1000;
      } else {
        // No dimensions: later entries usually higher quality
        area = i;
      }
      if (area >= bestArea) {
        bestArea = area;
        bestUrl = url;
      }
    }
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

  private readContent(record: Record<string, Object> | null): string {
    if (!record) {
      return '';
    }
    const content = this.asString(record['content']);
    if (content) {
      return content;
    }
    return this.readText(record);
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
