import { AuthSessionManager, AuthAccountStatus } from 'youtube_core';

export class AuthStateHelper {
  static refresh(): void {
    const session = AuthSessionManager.getInstance();
    const status = session ? session.getStatus() : new AuthAccountStatus();
    AppStorage.setOrCreate('authStatus', status);
  }
}
