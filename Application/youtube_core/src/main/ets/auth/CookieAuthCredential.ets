export class CookieAuthCredential {
  cookies: string = '';
  sapiSid: string = '';
  potToken: string = '';
  extractedAt: number = 0;

  static fromCookies(cookies: string, potToken: string = ''): CookieAuthCredential {
    const credential = new CookieAuthCredential();
    credential.cookies = cookies;
    credential.sapiSid = CookieAuthCredential.parseSapiSid(cookies);
    credential.potToken = potToken;
    credential.extractedAt = Date.now();
    return credential;
  }

  static parseSapiSid(cookies: string): string {
    const pairs = cookies.split(';');
    for (let i = 0; i < pairs.length; i++) {
      const pair = pairs[i].trim();
      const eqIdx = pair.indexOf('=');
      if (eqIdx < 0) {
        continue;
      }
      const name = pair.substring(0, eqIdx).trim();
      const value = pair.substring(eqIdx + 1).trim();
      if (name === 'SAPISID' && value.length > 0) {
        return value;
      }
      if (name === '__Secure-3PAPISID' && value.length > 0) {
        return value;
      }
    }
    return '';
  }

  static hasSid(cookies: string): boolean {
    const pairs = cookies.split(';');
    for (let i = 0; i < pairs.length; i++) {
      const pair = pairs[i].trim();
      const eqIdx = pair.indexOf('=');
      if (eqIdx < 0) {
        continue;
      }
      const name = pair.substring(0, eqIdx).trim();
      const value = pair.substring(eqIdx + 1).trim();
      if (name === 'SID' && value.length > 0) {
        return true;
      }
    }
    return false;
  }

  toJson(): string {
    return JSON.stringify({
      cookies: this.cookies,
      sapiSid: this.sapiSid,
      potToken: this.potToken,
      extractedAt: this.extractedAt
    });
  }

  static fromJson(json: string): CookieAuthCredential | null {
    try {
      const data = JSON.parse(json) as Record<string, Object>;
      const credential = new CookieAuthCredential();
      credential.cookies = (data['cookies'] as string) || '';
      credential.sapiSid = (data['sapiSid'] as string) || '';
      credential.potToken = (data['potToken'] as string) || '';
      credential.extractedAt = (data['extractedAt'] as number) || 0;
      return credential;
    } catch (e) {
      return null;
    }
  }
}
