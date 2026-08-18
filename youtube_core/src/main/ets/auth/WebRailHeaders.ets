/**
 * Shared WEB-rail (Cookie + SAPISIDHASH) auth header assembly.
 *
 * Single source for the header shape used by both the playback rail
 * (YouTubeHttpClient.injectWebAuthHeaders) and the browse rail
 * (YoutubeApi.applyAuthHeaders): Cookie / X-Origin / DNT / Authorization.
 * Intentional rail differences stay at the call sites:
 * - which session getters feed cookieString/authorization (playback vs userData),
 * - appendSocsWhenMissing: browse keeps the consent cookie (append SOCS when
 *   missing); playback overwrites the cookie header with the account cookie,
 * - header value wrapping (string vs string[]) and logging.
 */

/** Consent cookie appended on anonymous/consent-keeping WEB requests. */
export const SOCS_CONSENT_COOKIE: string = 'SOCS=CAISAiAD';

const WEB_RAIL_ORIGIN: string = 'https://www.youtube.com';

/**
 * Build the WEB-rail auth header set.
 * Cookie / X-Origin / DNT are only emitted when cookieString is non-empty;
 * Authorization is emitted independently when non-empty.
 */
export function buildWebRailHeaders(
  cookieString: string,
  authorization: string,
  appendSocsWhenMissing: boolean
): Record<string, string> {
  const headers: Record<string, string> = {};
  if (cookieString.length > 0) {
    let cookie = cookieString;
    if (appendSocsWhenMissing && cookie.indexOf('SOCS=') < 0) {
      cookie = `${cookie}; ${SOCS_CONSENT_COOKIE}`;
    }
    headers['Cookie'] = cookie;
    headers['X-Origin'] = WEB_RAIL_ORIGIN;
    headers['DNT'] = '1';
  }
  if (authorization.length > 0) {
    headers['Authorization'] = authorization;
  }
  return headers;
}
