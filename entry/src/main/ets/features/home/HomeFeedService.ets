import { AuthSessionManager, VideoItem } from 'youtube_core';
import { ContentCountry, Localization, fetchBrowseContinuation, fetchBrowsePage } from 'youtube_core';
import { buildHomeKioskVideoItems, getHomeFeedItemsFromTabContent } from './utils/HomeFeedUtils';

export interface KioskPageResult {
  items: Array<VideoItem>;
  nextPageToken: string | null;
  visitorData: string;
  source: string;
}

export class HomeFeedService {
  private localization: Localization;
  private contentCountry: ContentCountry;
  private readonly KIOSK_BROWSE_ID: string = 'UC4R8DWoMoI7CAwX8_LjQHig';
  private readonly KIOSK_PARAMS: string = 'EgdsaXZldGFikgEDCKEK';
  private readonly RECOMMENDED_BROWSE_ID: string = 'FEwhat_to_watch';

  constructor(localization: Localization, contentCountry: ContentCountry) {
    this.localization = localization;
    this.contentCountry = contentCountry;
  }

  /**
   * @param style 'recommended' | 'kiosk' — only applies when signed in.
   *              Signed-out always uses live kiosk.
   *              recommended failure does NOT fall back to kiosk.
   */
  async fetchHomeKioskInitial(startId: number, style: string = 'recommended'): Promise<KioskPageResult> {
    const signedIn = AuthSessionManager.getInstance()?.isSignedIn() === true;
    const useRecommended = signedIn && style !== 'kiosk';

    if (useRecommended) {
      const recommended = await this.fetchBrowseSource(
        this.RECOMMENDED_BROWSE_ID,
        '',
        true,
        startId,
        'recommended'
      );
      if (recommended.items.length === 0) {
        throw new Error('Empty recommended feed');
      }
      return recommended;
    }

    return this.fetchBrowseSource(
      this.KIOSK_BROWSE_ID,
      this.KIOSK_PARAMS,
      false,
      startId,
      'kiosk'
    );
  }

  async fetchHomeKioskNext(
    nextPageToken: string,
    visitorData: string,
    startId: number,
    withAuth: boolean = false
  ): Promise<KioskPageResult> {
    const useAuth = withAuth && AuthSessionManager.getInstance()?.isSignedIn() === true;
    const response = await fetchBrowseContinuation(
      this.localization,
      this.contentCountry,
      nextPageToken,
      visitorData,
      useAuth
    );
    if (!response) {
      throw new Error('Empty browse continuation response');
    }
    const parsed = this.parseHomeBrowseContinuationResponse(
      response as Record<string, Object>,
      visitorData,
      startId
    );
    parsed.source = useAuth ? 'recommended' : 'kiosk';
    return parsed;
  }

  private async fetchBrowseSource(
    browseId: string,
    params: string,
    withAuth: boolean,
    startId: number,
    source: string
  ): Promise<KioskPageResult> {
    const response = await fetchBrowsePage(
      this.localization,
      this.contentCountry,
      browseId,
      params,
      undefined,
      withAuth
    );
    if (!response) {
      throw new Error('Empty browse response');
    }
    const parsed = this.parseHomeBrowseInitialResponse(response as Record<string, Object>, startId);
    parsed.source = source;
    return parsed;
  }

  private parseHomeBrowseInitialResponse(response: Record<string, Object>, startId: number): KioskPageResult {
    const responseContext = response["responseContext"] as Record<string, Object>;
    const visitorData = (responseContext ? (responseContext["visitorData"] as string) : "") || "";

    const contents = response["contents"] as Record<string, Object>;
    const twoColumn = contents ? (contents["twoColumnBrowseResultsRenderer"] as Record<string, Object>) : undefined;
    const tabs = twoColumn ? (twoColumn["tabs"] as Array<Record<string, Object>>) : undefined;
    const tab0 = tabs && tabs.length > 0 ? tabs[0] : undefined;
    const tabRenderer = tab0 ? (tab0["tabRenderer"] as Record<string, Object>) : undefined;
    let tabContent = tabRenderer ? (tabRenderer["content"] as Record<string, Object>) : undefined;

    if (!tabContent && contents) {
      tabContent = contents;
    }

    const rawItems: Array<Record<string, Object>> = getHomeFeedItemsFromTabContent(tabContent);
    const built = buildHomeKioskVideoItems(rawItems, startId, '');
    return {
      items: built.items,
      nextPageToken: built.nextPageToken,
      visitorData,
      source: 'kiosk'
    };
  }

  private parseHomeBrowseContinuationResponse(
    response: Record<string, Object>,
    visitorData: string,
    startId: number
  ): KioskPageResult {
    let items: Array<VideoItem> = [];
    let nextPageToken: string | null = null;

    const actions = response["onResponseReceivedActions"] as Array<Record<string, Object>>;
    if (actions && actions.length > 0) {
      actions.forEach((action) => {
        const append = action["appendContinuationItemsAction"] as Record<string, Object>;
        const continuationItems = append ? (append["continuationItems"] as Array<Record<string, Object>>) : undefined;
        if (!continuationItems || continuationItems.length === 0) {
          return;
        }
        const expanded = this.expandContinuationItems(continuationItems);
        const built = buildHomeKioskVideoItems(expanded, startId + items.length, '');
        items = items.concat(built.items);
        nextPageToken = built.nextPageToken ?? nextPageToken;
      });
    }

    return { items, nextPageToken, visitorData, source: 'kiosk' };
  }

  private expandContinuationItems(items: Array<Record<string, Object>>): Array<Record<string, Object>> {
    const result: Array<Record<string, Object>> = [];
    items.forEach((item) => {
      const richSection = item["richSectionRenderer"] as Record<string, Object>;
      if (richSection) {
        const content = richSection["content"] as Record<string, Object>;
        const shelf = content ? (content["richShelfRenderer"] as Record<string, Object>) : undefined;
        const shelfContents = shelf ? (shelf["contents"] as Array<Record<string, Object>>) : undefined;
        if (shelfContents && shelfContents.length > 0) {
          shelfContents.forEach((c) => result.push(c));
          return;
        }
      }
      result.push(item);
    });
    return result;
  }
}
