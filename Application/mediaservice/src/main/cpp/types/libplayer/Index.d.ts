// index.d.ts - TypeScript definitions for libplayer
// Native local media proxy for HarmonyOS

export const localMediaCreateSession: (inputJson: string) => string;
export const localMediaDestroySession: (sessionId: string) => void;
export const localMediaGetPlaybackUrl: (sessionId: string) => string;
export const localMediaRefreshSession: (sessionId: string, inputJson: string) => string;
export const localMediaStopAll: () => void;
export const localMediaSetCacheConfig: (configJson: string) => void;
export const localMediaGetCacheStats: () => string;
export const localMediaClearCache: () => void;
