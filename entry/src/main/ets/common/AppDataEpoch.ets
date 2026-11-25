/** Process-local write fence for restore/clear operations. No user data is persisted. */
export class AppDataEpoch {
  private static revision: number = 0;
  private static recoveryLease: number = -1;

  static capture(): number {
    return AppDataEpoch.revision;
  }

  static invalidate(): void {
    AppDataEpoch.revision++;
  }

  static beginRecovery(): number {
    if (AppDataEpoch.recoveryLease >= 0) throw new Error('Data recovery is already running');
    AppDataEpoch.recoveryLease = ++AppDataEpoch.revision;
    return AppDataEpoch.recoveryLease;
  }

  static finishRecovery(lease: number): void {
    if (lease !== AppDataEpoch.recoveryLease) return;
    AppDataEpoch.recoveryLease = -1;
    // Requests started during recovery are stale as well.
    AppDataEpoch.revision++;
  }

  static isCurrent(revision: number): boolean {
    return AppDataEpoch.recoveryLease < 0 && revision === AppDataEpoch.revision;
  }
}
