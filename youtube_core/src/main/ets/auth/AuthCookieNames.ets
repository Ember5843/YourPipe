/**
 * Account-scoped YouTube cookies. These belong to the credential store
 * (AuthSessionManager), never to the anonymous CookieJar: the jar is attached
 * to every request (including withAuth=false), so storing/replaying them there
 * would authenticate "guest" requests as the previous account.
 *
 * Keep this list in sync with the account cookies the dual-rail auth layer
 * merges from Set-Cookie (SID family, SAPISID family, LOGIN_INFO, SIDCC family).
 */
const ACCOUNT_COOKIE_NAMES: string[] = [
  'SID', 'HSID', 'SSID', 'APISID', 'SAPISID',
  '__Secure-1PAPISID', '__Secure-3PAPISID',
  '__Secure-1PSID', '__Secure-3PSID',
  'LOGIN_INFO',
  'SIDCC', '__Secure-1PSIDCC', '__Secure-3PSIDCC'
];

export function isAccountCookieName(name: string): boolean {
  return ACCOUNT_COOKIE_NAMES.indexOf(name) >= 0;
}
