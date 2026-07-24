import { VideoBuildResult } from '../model/FeedResult';
import { buildHomeKioskVideoItems } from './HomeFeedUtils';
import { getContinuationToken } from './ContinuationUtils';

/**
 * SmartTube-style TV browse JSON walkers.
 *
 * Home path:
 *   contents.tvBrowseRenderer.content.tvSurfaceContentRenderer.content
 * Subs/history/library path:
 *   contents.tvBrowseRenderer.content.tvSecondaryNavRenderer
 *     .sections[0].tvSecondaryNavSectionRenderer.tabs[selected]
 *     .tabRenderer.content.tvSurfaceContentRenderer.content
 * Then: sectionListRenderer shelves | gridRenderer items (tile/gridVideo)
 */

export function getTvSurfaceContent(response: Record<string, Object>): Record<string, Object> | undefined {
  const contents = response['contents'] as Record<string, Object>;
  if (!contents) {
    return undefined;
  }
  const tvBrowse = contents['tvBrowseRenderer'] as Record<string, Object>;
  if (!tvBrowse) {
    return undefined;
  }
  const content = tvBrowse['content'] as Record<string, Object>;
  if (!content) {
    return undefined;
  }

  // Direct surface (TV home browseId=default)
  const direct = extractSurfaceFromNode(content);
  if (direct) {
    return direct;
  }

  // Secondary nav tabs (subscriptions / history / library / channels)
  return getSelectedTabSurfaceContent(content);
}

/** Surface content under a tabRenderer / expandableTabRenderer content node. */
function extractSurfaceFromNode(node: Record<string, Object> | undefined): Record<string, Object> | undefined {
  if (!node) {
    return undefined;
  }
  const surface = node['tvSurfaceContentRenderer'] as Record<string, Object>;
  if (surface) {
    const inner = surface['content'] as Record<string, Object>;
    if (inner) {
      return inner;
    }
  }
  return undefined;
}

/**
 * Prefer selected tab; else first tab that already embeds content.
 * Matches SmartTube BrowseResultTV.getSubscriptionsTab().
 */
function getSelectedTabSurfaceContent(content: Record<string, Object>): Record<string, Object> | undefined {
  const secondary = content['tvSecondaryNavRenderer'] as Record<string, Object>;
  if (!secondary) {
    return undefined;
  }
  const sections = secondary['sections'] as Array<Record<string, Object>>;
  if (!sections || sections.length === 0) {
    return undefined;
  }
  const section0 = sections[0]['tvSecondaryNavSectionRenderer'] as Record<string, Object>;
  const tabs = section0 ? (section0['tabs'] as Array<Record<string, Object>>) : undefined;
  if (!tabs || tabs.length === 0) {
    return undefined;
  }

  let firstWithContent: Record<string, Object> | undefined = undefined;
  for (let i = 0; i < tabs.length; i++) {
    const tab = tabs[i];
    const tabRenderer = (tab['tabRenderer'] as Record<string, Object>)
      || (tab['expandableTabRenderer'] as Record<string, Object>);
    if (!tabRenderer) {
      continue;
    }
    const tabContent = tabRenderer['content'] as Record<string, Object>;
    const surface = extractSurfaceFromNode(tabContent);
    if (!surface) {
      continue;
    }
    if (tabRenderer['selected'] === true) {
      return surface;
    }
    if (!firstWithContent) {
      firstWithContent = surface;
    }
  }
  return firstWithContent;
}

export function getTvVisitorData(response: Record<string, Object>): string {
  const responseContext = response['responseContext'] as Record<string, Object>;
  return (responseContext ? (responseContext['visitorData'] as string) : '') || '';
}

/**
 * Flatten TV browse initial/continuation payload into leaf nodes for VideoItemBuilder.
 */
export function getTvBrowseRawItems(response: Record<string, Object>): Array<Record<string, Object>> {
  const out: Array<Record<string, Object>> = [];
  const surface = getTvSurfaceContent(response);
  if (surface) {
    collectTvLeaves(surface, out);
  }
  if (out.length === 0) {
    collectTvLeaves(response, out);
  }
  const actions = response['onResponseReceivedActions'] as Array<Record<string, Object>>;
  if (actions) {
    actions.forEach((action) => {
      const append = action['appendContinuationItemsAction'] as Record<string, Object>;
      const items = append ? (append['continuationItems'] as Array<Record<string, Object>>) : undefined;
      if (items) {
        items.forEach((n) => collectTvLeaves(n, out));
      }
      const reload = action['reloadContinuationItemsCommand'] as Record<string, Object>;
      const reloadItems = reload
        ? (reload['continuationItems'] as Array<Record<string, Object>>)
        : undefined;
      if (reloadItems) {
        reloadItems.forEach((n) => collectTvLeaves(n, out));
      }
    });
  }
  const continuationContents = response['continuationContents'] as Record<string, Object>;
  if (continuationContents) {
    collectTvLeaves(continuationContents, out);
  }
  return out;
}

export function getTvContinuationToken(response: Record<string, Object>): string | null {
  const surface = getTvSurfaceContent(response);
  if (surface) {
    const fromSurface = findContinuationInNode(surface);
    if (fromSurface) {
      return fromSurface;
    }
  }
  const fromRoot = findContinuationInNode(response);
  if (fromRoot) {
    return fromRoot;
  }
  const actions = response['onResponseReceivedActions'] as Array<Record<string, Object>>;
  if (actions) {
    for (let i = 0; i < actions.length; i++) {
      const action = actions[i];
      const append = action['appendContinuationItemsAction'] as Record<string, Object>;
      const items = append ? (append['continuationItems'] as Array<Record<string, Object>>) : undefined;
      if (items) {
        for (let j = 0; j < items.length; j++) {
          const t = findContinuationInNode(items[j]);
          if (t) {
            return t;
          }
        }
      }
    }
  }
  return null;
}

export function buildTvBrowseVideoItems(
  response: Record<string, Object>,
  startId: number
): VideoBuildResult {
  const raw = getTvBrowseRawItems(response);
  const built = buildHomeKioskVideoItems(raw, startId, '');
  if (!built.nextPageToken) {
    built.nextPageToken = getTvContinuationToken(response);
  }
  return built;
}

function collectTvLeaves(node: Record<string, Object>, out: Array<Record<string, Object>>): void {
  if (!node) {
    return;
  }

  // Nested surface under secondary-nav tab content
  const nestedSurface = extractSurfaceFromNode(node);
  if (nestedSurface && nestedSurface !== node) {
    collectTvLeaves(nestedSurface, out);
    return;
  }

  const secondary = node['tvSecondaryNavRenderer'] as Record<string, Object>;
  if (secondary) {
    const surface = getSelectedTabSurfaceContent(node);
    if (surface) {
      collectTvLeaves(surface, out);
      return;
    }
  }

  if (node['richItemRenderer'] || node['gridVideoRenderer'] || node['reelItemRenderer']
    || node['lockupViewModel'] || node['shortsLockupViewModel'] || node['videoRenderer']
    || node['compactVideoRenderer'] || node['videoWithContextRenderer']
    || node['tileRenderer'] || node['gridPlaylistRenderer'] || node['gridChannelRenderer']
    || node['continuationItemRenderer']) {
    out.push(node);
    return;
  }

  const sectionList = node['sectionListRenderer'] as Record<string, Object>;
  if (sectionList) {
    const contents = sectionList['contents'] as Array<Record<string, Object>>;
    if (contents) {
      contents.forEach((c) => collectTvLeaves(c, out));
    }
    pushContinuationArray(sectionList['continuations'] as Array<Record<string, Object>>, out);
    return;
  }

  const sectionListCont = node['sectionListContinuation'] as Record<string, Object>;
  if (sectionListCont) {
    const contents = sectionListCont['contents'] as Array<Record<string, Object>>;
    if (contents) {
      contents.forEach((c) => collectTvLeaves(c, out));
    }
    pushContinuationArray(sectionListCont['continuations'] as Array<Record<string, Object>>, out);
    return;
  }

  const shelf = node['shelfRenderer'] as Record<string, Object>;
  if (shelf) {
    const shelfContent = shelf['content'] as Record<string, Object>;
    if (shelfContent) {
      collectTvLeaves(shelfContent, out);
    }
    const items = shelf['items'] as Array<Record<string, Object>>;
    if (items) {
      items.forEach((c) => collectTvLeaves(c, out));
    }
    return;
  }

  const grid = node['gridRenderer'] as Record<string, Object>;
  if (grid) {
    const items = grid['items'] as Array<Record<string, Object>>;
    if (items) {
      items.forEach((c) => collectTvLeaves(c, out));
    }
    pushContinuationArray(grid['continuations'] as Array<Record<string, Object>>, out);
    return;
  }

  const gridCont = node['gridContinuation'] as Record<string, Object>;
  if (gridCont) {
    const items = gridCont['items'] as Array<Record<string, Object>>;
    if (items) {
      items.forEach((c) => collectTvLeaves(c, out));
    }
    pushContinuationArray(gridCont['continuations'] as Array<Record<string, Object>>, out);
    return;
  }

  const horizontal = node['horizontalListRenderer'] as Record<string, Object>;
  if (horizontal) {
    const items = horizontal['items'] as Array<Record<string, Object>>;
    if (items) {
      items.forEach((c) => collectTvLeaves(c, out));
    }
    return;
  }

  const expanded = node['expandedShelfContentsRenderer'] as Record<string, Object>;
  if (expanded) {
    const items = expanded['items'] as Array<Record<string, Object>>;
    if (items) {
      items.forEach((c) => collectTvLeaves(c, out));
    }
    return;
  }

  const itemSection = node['itemSectionRenderer'] as Record<string, Object>;
  if (itemSection) {
    const contents = itemSection['contents'] as Array<Record<string, Object>>;
    if (contents) {
      contents.forEach((c) => collectTvLeaves(c, out));
    }
    return;
  }

  const tvBrowse = node['tvBrowseRenderer'] as Record<string, Object>;
  if (tvBrowse) {
    collectTvLeaves(tvBrowse, out);
    return;
  }

  const surface = node['tvSurfaceContentRenderer'] as Record<string, Object>;
  if (surface) {
    const content = surface['content'] as Record<string, Object>;
    if (content) {
      collectTvLeaves(content, out);
    }
    return;
  }

  const twoCol = node['twoColumnRenderer'] as Record<string, Object>;
  if (twoCol) {
    const right = twoCol['rightColumn'] as Record<string, Object>;
    if (right) {
      collectTvLeaves(right, out);
    }
    return;
  }

  const playlistList = node['playlistVideoListRenderer'] as Record<string, Object>;
  if (playlistList) {
    const contents = playlistList['contents'] as Array<Record<string, Object>>;
    if (contents) {
      contents.forEach((c) => collectTvLeaves(c, out));
    }
    return;
  }

  const contents = node['contents'] as Array<Record<string, Object>>;
  if (contents && Array.isArray(contents)) {
    contents.forEach((c) => collectTvLeaves(c, out));
  }
  const items = node['items'] as Array<Record<string, Object>>;
  if (items && Array.isArray(items)) {
    items.forEach((c) => collectTvLeaves(c, out));
  }
}

function pushContinuationArray(
  continuations: Array<Record<string, Object>> | undefined,
  out: Array<Record<string, Object>>
): void {
  if (!continuations) {
    return;
  }
  for (let i = 0; i < continuations.length; i++) {
    const c = continuations[i];
    const next = c['nextContinuationData'] as Record<string, Object>;
    const token = next ? (next['continuation'] as string) : '';
    if (token && token.length > 0) {
      const contCmd: Record<string, Object> = {};
      contCmd['token'] = token;
      const endpoint: Record<string, Object> = {};
      endpoint['continuationCommand'] = contCmd;
      const itemRenderer: Record<string, Object> = {};
      itemRenderer['continuationEndpoint'] = endpoint;
      const wrapper: Record<string, Object> = {};
      wrapper['continuationItemRenderer'] = itemRenderer;
      out.push(wrapper);
      return;
    }
  }
}

function findContinuationInNode(node: Record<string, Object>): string | null {
  if (!node) {
    return null;
  }
  const contItem = node['continuationItemRenderer'] as Record<string, Object>;
  if (contItem) {
    const t = getContinuationToken(contItem);
    if (t) {
      return t;
    }
  }
  const sectionList = node['sectionListRenderer'] as Record<string, Object>;
  if (sectionList) {
    const fromCont = tokenFromContinuations(sectionList['continuations'] as Array<Record<string, Object>>);
    if (fromCont) {
      return fromCont;
    }
    const contents = sectionList['contents'] as Array<Record<string, Object>>;
    if (contents) {
      for (let i = 0; i < contents.length; i++) {
        const t = findContinuationInNode(contents[i]);
        if (t) {
          return t;
        }
      }
    }
  }
  const grid = node['gridRenderer'] as Record<string, Object>;
  if (grid) {
    const fromCont = tokenFromContinuations(grid['continuations'] as Array<Record<string, Object>>);
    if (fromCont) {
      return fromCont;
    }
    const items = grid['items'] as Array<Record<string, Object>>;
    if (items) {
      for (let i = 0; i < items.length; i++) {
        const t = findContinuationInNode(items[i]);
        if (t) {
          return t;
        }
      }
    }
  }
  const shelf = node['shelfRenderer'] as Record<string, Object>;
  if (shelf) {
    const content = shelf['content'] as Record<string, Object>;
    if (content) {
      const t = findContinuationInNode(content);
      if (t) {
        return t;
      }
    }
  }
  const gridCont = node['gridContinuation'] as Record<string, Object>;
  if (gridCont) {
    return tokenFromContinuations(gridCont['continuations'] as Array<Record<string, Object>>);
  }
  const sectionCont = node['sectionListContinuation'] as Record<string, Object>;
  if (sectionCont) {
    return tokenFromContinuations(sectionCont['continuations'] as Array<Record<string, Object>>);
  }
  return null;
}

function tokenFromContinuations(continuations: Array<Record<string, Object>> | undefined): string | null {
  if (!continuations || continuations.length === 0) {
    return null;
  }
  for (let i = 0; i < continuations.length; i++) {
    const c = continuations[i];
    const next = c['nextContinuationData'] as Record<string, Object>;
    const token = next ? (next['continuation'] as string) : '';
    if (token && token.length > 0) {
      return token;
    }
    const reload = c['reloadContinuationData'] as Record<string, Object>;
    const reloadToken = reload ? (reload['continuation'] as string) : '';
    if (reloadToken && reloadToken.length > 0) {
      return reloadToken;
    }
  }
  return null;
}
