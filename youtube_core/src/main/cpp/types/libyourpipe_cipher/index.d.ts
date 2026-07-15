export interface NativePrepareResult {
  playerId: string;
  prepared: boolean;
  hasN: boolean;
  hasSig: boolean;
}

export interface NativeRuntimeInfo {
  engine: string;
  apiVersion: number;
  jitRequested: boolean;
  preparedPlayers: number;
}

export function preprocessPlayer(playerJs: string): Promise<string>;
export function preparePlayer(playerId: string, preprocessedPlayer: string): Promise<NativePrepareResult>;
export function decodeBatch(playerId: string, sigs: string[], nParams: string[]): Promise<string>;
export function evictPlayer(playerId: string): Promise<void>;
export function getRuntimeInfo(): NativeRuntimeInfo;
/** True when system Secure Shield (坚盾守护) mode is on — JIT disabled globally. */
export function isSecureShieldMode(): boolean;
export function shutdown(): Promise<void>;
