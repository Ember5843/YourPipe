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

interface HeaderMetadataPart {
  content: string;
  hasLabel: boolean;
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
    // vanityChannelUrl is a full URL (https://www.youtube.com/@handle) — keep
    // only the '@handle' part.
    const metadata = this.asRecord(root['metadata']);
    const channelMetadata = this.asRecord(metadata?.['channelMetadataRenderer']);
    const handle = this.handleFromVanityUrl(this.asString(channelMetadata?.['vanityChannelUrl']));
    if (handle) {
      return handle;
    }
    const header = this.asRecord(root['header']);
    const c4 = this.asRecord(header?.['c4TabbedHeaderRenderer']);
    const c4Handle = c4 ? this.readText(c4['vanityChannelUrl']) : '';
    return this.handleFromVanityUrl(c4Handle);
  }

  private handleFromVanityUrl(url: string): string {
    const at = (url || '').indexOf('@');
    return at >= 0 ? url.substring(at) : '';
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
        const parts = this.readHeaderMetadataParts(pageHeader);
        // First pass: explicit "subscriber" keyword (English responses).
        for (const part of parts) {
          if (part.content.toLowerCase().includes('subscriber')) {
            return part.content;
          }
        }
        // Fallback for localized responses: current layout is
        // [@handle (no label), subscribers (has accessibilityLabel), videos (no label)] —
        // the subscriber count is the labeled part that is not the handle.
        for (const part of parts) {
          if (part.hasLabel && !part.content.startsWith('@')) {
            return part.content;
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
        const parts = this.readHeaderMetadataParts(pageHeader);
        // First pass: explicit "video" keyword (English responses).
        for (const part of parts) {
          if (part.content.toLowerCase().includes('video')) {
            return part.content;
          }
        }
        // Fallback for localized responses: the video count is the non-@
        // part WITHOUT an accessibilityLabel (the labeled one is the
        // subscriber count). If every candidate is labeled, take the one
        // after the subscriber part.
        const candidates = parts.filter(p => p.content.length > 0 && !p.content.startsWith('@'));
        const unlabeled = candidates.filter(p => !p.hasLabel);
        if (unlabeled.length > 0) {
          return unlabeled[0].content;
        }
        if (candidates.length > 1) {
          return candidates[1].content;
        }
      }
    }

    // Fallback: check metadata.channelMetadataRenderer (no video count available here)
    return '';
  }

  /** Flatten pageHeaderRenderer metadata parts: [@handle, subscribers (labeled), videos, ...]. */
  private readHeaderMetadataParts(pageHeader: Record<string, Object>): HeaderMetadataPart[] {
    const result: HeaderMetadataPart[] = [];
    const pageHeaderContent = this.asRecord(pageHeader['content']);
    const pageHeaderViewModel = this.asRecord(pageHeaderContent?.['pageHeaderViewModel']);
    const metadata = this.asRecord(pageHeaderViewModel?.['metadata']);
    const contentMetadata = this.asRecord(metadata?.['contentMetadataViewModel']);
    const metadataRows = this.asArray(contentMetadata?.['metadataRows']);
    if (!metadataRows) {
      return result;
    }
    for (let r = 0; r < metadataRows.length; r++) {
      const row = this.asRecord(metadataRows[r]);
      const parts = this.asArray(row?.['metadataParts']);
      if (!parts) {
        continue;
      }
      for (let p = 0; p < parts.length; p++) {
        const part = this.asRecord(parts[p]);
        const text = this.asRecord(part?.['text']);
        const content = this.asString(text?.['content']);
        if (content) {
          result.push({ content: content, hasLabel: !!part?.['accessibilityLabel'] });
        }
      }
    }
    return result;
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
