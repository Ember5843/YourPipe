import { AuthExpiredError, AuthSessionManager, VideoItem } from 'youtube_core';
import {
  ContentCountry,
  Localization,
  fetchBrowseContinuation,
  fetchBrowsePage,
  fetchTvBrowseContinuation,
  fetchTvBrowsePage
} from 'youtube_core';
import { AppLog } from '../../common/AppLog';
import { buildHomeKioskVideoItems, getHomeFeedItemsFromTabContent } from './utils/HomeFeedUtils';
import { buildTvBrowseVideoItems, getTvVisitorData } from './utils/TvBrowseUtils';

const logger = AppLog.getInstance('HomeFeedService');

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
  /** SmartTube TV home browseId. */
  private readonly TV_HOME_BROWSE_ID: string = 'default';

  constructor(localization: Localization, contentCountry: ContentCountry) {
    this.localization = localization;
    this.contentCountry = contentCountry;
  }

  /**
   * @param style 'recommended' | 'kiosk' — only applies when signed in.
   *              Signed-out always uses live kiosk.
   *              recommended failure falls back to the guest kiosk; an
   *              AuthExpiredError is reported via AuthSessionManager.noteAuthRejection.
   * Rails: WEB Cookie → FEwhat_to_watch; OAuth-only → TV browseId=default; else kiosk.
   */
  async fetchHomeKioskInitial(startId: number, style: string = 'recommended'): Promise<KioskPageResult> {
    const session = AuthSessionManager.getInstance();
    const rail = style !== 'kiosk' ? (session?.preferredUserDataRail() || 'none') : 'none';
    const startedAt = Date.now();
    logger.info(`[HomeFeed] stage=initial_start style=${style} rail=${rail}`);

    if (rail === 'web') {
      try {
        const recommended = await this.fetchWebBrowseSource(
          this.RECOMMENDED_BROWSE_ID,
          '',
          true,
          startId,
          'recommended-web'
        );
        if (recommended.items.length === 0) {
          throw new Error('Empty recommended feed');
        }
        logger.info(`[HomeFeed] stage=initial_done source=recommended-web items=${recommended.items.length} `
          + `elapsed=${Date.now() - startedAt}ms hasNext=${!!recommended.nextPageToken}`);
        return recommended;
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (e instanceof AuthExpiredError) {
          session?.noteAuthRejection('web', 'browse-rejected');
        }
        logger.warn(`[HomeFeed] stage=initial_failed source=recommended-web `
          + `elapsed=${Date.now() - startedAt}ms message=${msg} — falling back to kiosk`);
      }
    }

    if (rail === 'tv') {
      try {
        const tvHome = await this.fetchTvHomeSource(startId);
        if (tvHome.items.length === 0) {
          throw new Error('Empty TV recommended feed');
        }
        logger.info(`[HomeFeed] stage=initial_done source=recommended-tv items=${tvHome.items.length} `
          + `elapsed=${Date.now() - startedAt}ms hasNext=${!!tvHome.nextPageToken}`);
        return tvHome;
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (e instanceof AuthExpiredError) {
          session?.noteAuthRejection('tv', 'browse-rejected');
        }
        logger.warn(`[HomeFeed] stage=initial_failed source=recommended-tv `
          + `elapsed=${Date.now() - startedAt}ms message=${msg} — falling back to kiosk`);
      }
    }

    if (style === 'recommended' && session?.isAuthEnabledForUserData() === true) {
      logger.warn('[HomeFeed] recommended requested but no WEB/TV credential — using live kiosk');
    }

    try {
      const kiosk = await this.fetchWebBrowseSource(
        this.KIOSK_BROWSE_ID,
        this.KIOSK_PARAMS,
        false,
        startId,
        'kiosk'
      );
      logger.info(`[HomeFeed] stage=initial_done source=kiosk items=${kiosk.items.length} `
        + `elapsed=${Date.now() - startedAt}ms hasNext=${!!kiosk.nextPageToken}`);
      return kiosk;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      logger.error(`[HomeFeed] stage=initial_failed source=kiosk `
        + `elapsed=${Date.now() - startedAt}ms message=${msg}`);
      throw e instanceof Error ? e : new Error(msg);
    }
  }

  /**
   * Continuation for home feed. sourceRail is inferred from withAuth + credentials,
   * or callers may pass previous source via withAuth + homeFeedSource encoding:
   * Index uses withAuth when homeFeedSource starts with recommended.
   */
  async fetchHomeKioskNext(
    nextPageToken: string,
    visitorData: string,
    startId: number,
    withAuth: boolean = false,
    previousSource: string = ''
  ): Promise<KioskPageResult> {
    const session = AuthSessionManager.getInstance();
    const startedAt = Date.now();
    const sourceHint = previousSource.length > 0 ? previousSource : '';
    const useTv = sourceHint === 'recommended-tv'
      || (withAuth && session?.hasTvAuthForUserData() === true
        && session?.hasCookieAuthForUserData() !== true);
    const useWebAuth = withAuth
      && session?.isAuthEnabledForUserData() === true
      && session?.hasCookieAuthForUserData() === true
      && !useTv;

    logger.info(`[HomeFeed] stage=next_start tv=${useTv} webAuth=${useWebAuth} `
      + `tokenLen=${nextPageToken.length} hint=${sourceHint}`);

    try {
      if (useTv) {
        const response = await fetchTvBrowseContinuation(
          this.localization,
          this.contentCountry,
          nextPageToken,
          visitorData,
          true
        );
        if (!response) {
          throw new Error('Empty TV browse continuation response');
        }
        const built = buildTvBrowseVideoItems(response as Record<string, Object>, startId);
        const result: KioskPageResult = {
          items: built.items,
          nextPageToken: built.nextPageToken,
          visitorData: getTvVisitorData(response as Record<string, Object>) || visitorData,
          source: 'recommended-tv'
        };
        logger.info(`[HomeFeed] stage=next_done source=recommended-tv items=${result.items.length} `
          + `elapsed=${Date.now() - startedAt}ms hasNext=${!!result.nextPageToken}`);
        return result;
      }

      const response = await fetchBrowseContinuation(
        this.localization,
        this.contentCountry,
        nextPageToken,
        visitorData,
        useWebAuth
      );
      if (!response) {
        throw new Error('Empty browse continuation response');
      }
      const parsed = this.parseHomeBrowseContinuationResponse(
        response as Record<string, Object>,
        visitorData,
        startId
      );
      parsed.source = useWebAuth ? 'recommended-web' : 'kiosk';
      logger.info(`[HomeFeed] stage=next_done source=${parsed.source} items=${parsed.items.length} `
        + `elapsed=${Date.now() - startedAt}ms hasNext=${!!parsed.nextPageToken}`);
      return parsed;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      logger.error(`[HomeFeed] stage=next_failed `
        + `elapsed=${Date.now() - startedAt}ms message=${msg}`);
      throw e instanceof Error ? e : new Error(msg);
    }
  }

  private async fetchTvHomeSource(startId: number): Promise<KioskPageResult> {
    const startedAt = Date.now();
    logger.info(`[HomeFeed] stage=browse_start source=recommended-tv browseId=${this.TV_HOME_BROWSE_ID}`);
    const response = await fetchTvBrowsePage(
      this.localization,
      this.contentCountry,
      this.TV_HOME_BROWSE_ID,
      '',
      undefined,
      true
    );
    if (!response) {
      throw new Error('Empty TV browse response browseId=default');
    }
    const resp = response as Record<string, Object>;
    const error = resp['error'] as Record<string, Object>;
    if (error) {
      throw new Error(`TV browse error: ${JSON.stringify(error)}`);
    }
    const built = buildTvBrowseVideoItems(resp, startId);
    if (built.items.length === 0) {
      const keys = Object.keys(resp).join(',');
      const contents = resp['contents'] as Record<string, Object>;
      const contentKeys = contents ? Object.keys(contents).join(',') : '(none)';
      const tvBrowse = contents ? (contents['tvBrowseRenderer'] as Record<string, Object>) : undefined;
      const tvContent = tvBrowse ? (tvBrowse['content'] as Record<string, Object>) : undefined;
      const tvContentKeys = tvContent ? Object.keys(tvContent).join(',') : '(none)';
      const err = resp['error'] as Record<string, Object>;
      logger.warn(`[HomeFeed] stage=browse_empty source=recommended-tv topKeys=${keys} `
        + `contentsKeys=${contentKeys} tvContentKeys=${tvContentKeys} hasError=${!!err}`);
    }
    logger.info(`[HomeFeed] stage=browse_parsed source=recommended-tv items=${built.items.length} `
      + `elapsed=${Date.now() - startedAt}ms`);
    return {
      items: built.items,
      nextPageToken: built.nextPageToken,
      visitorData: getTvVisitorData(resp),
      source: 'recommended-tv'
    };
  }

  private async fetchWebBrowseSource(
    browseId: string,
    params: string,
    withAuth: boolean,
    startId: number,
    source: string
  ): Promise<KioskPageResult> {
    const startedAt = Date.now();
    logger.info(`[HomeFeed] stage=browse_start source=${source} browseId=${browseId} withAuth=${withAuth}`);
    const response = await fetchBrowsePage(
      this.localization,
      this.contentCountry,
      browseId,
      params,
      undefined,
      withAuth
    );
    if (!response) {
      throw new Error(`Empty browse response source=${source} browseId=${browseId}`);
    }
    const parsed = this.parseHomeBrowseInitialResponse(response as Record<string, Object>, startId);
    parsed.source = source;
    logger.info(`[HomeFeed] stage=browse_parsed source=${source} items=${parsed.items.length} `
      + `elapsed=${Date.now() - startedAt}ms`);
    return parsed;
  }

  private parseHomeBrowseInitialResponse(response: Record<string, Object>, startId: number): KioskPageResult {
    const responseContext = response['responseContext'] as Record<string, Object>;
    const visitorData = (responseContext ? (responseContext['visitorData'] as string) : '') || '';

    const contents = response['contents'] as Record<string, Object>;
    const twoColumn = contents ? (contents['twoColumnBrowseResultsRenderer'] as Record<string, Object>) : undefined;
    const tabs = twoColumn ? (twoColumn['tabs'] as Array<Record<string, Object>>) : undefined;
    const tab0 = tabs && tabs.length > 0 ? tabs[0] : undefined;
    const tabRenderer = tab0 ? (tab0['tabRenderer'] as Record<string, Object>) : undefined;
    let tabContent = tabRenderer ? (tabRenderer['content'] as Record<string, Object>) : undefined;

    if (!tabContent && contents) {
      tabContent = contents;
    }

    const rawItems: Array<Record<string, Object>> = getHomeFeedItemsFromTabContent(tabContent);
    const built = buildHomeKioskVideoItems(rawItems, startId, 'LIVE');
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

    const actions = response['onResponseReceivedActions'] as Array<Record<string, Object>>;
    if (actions && actions.length > 0) {
      actions.forEach((action) => {
        const append = action['appendContinuationItemsAction'] as Record<string, Object>;
        const continuationItems = append ? (append['continuationItems'] as Array<Record<string, Object>>) : undefined;
        if (!continuationItems || continuationItems.length === 0) {
          return;
        }
        const expanded = this.expandContinuationItems(continuationItems);
        const built = buildHomeKioskVideoItems(expanded, startId + items.length, 'LIVE');
        items = items.concat(built.items);
        nextPageToken = built.nextPageToken ?? nextPageToken;
      });
    }

    return { items, nextPageToken, visitorData, source: 'kiosk' };
  }

  private expandContinuationItems(items: Array<Record<string, Object>>): Array<Record<string, Object>> {
    const result: Array<Record<string, Object>> = [];
    items.forEach((item) => {
      const richSection = item['richSectionRenderer'] as Record<string, Object>;
      if (richSection) {
        const content = richSection['content'] as Record<string, Object>;
        const shelf = content ? (content['richShelfRenderer'] as Record<string, Object>) : undefined;
        const shelfContents = shelf ? (shelf['contents'] as Array<Record<string, Object>>) : undefined;
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
