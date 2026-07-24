# Dual-Rail Auth Plan (Cookie/WEB + OAuth/TV)

## Goal
Keep existing Cookie/WEB capabilities, add parallel OAuth/TV rail so device QR login can power personalized home, user data, and auth-enhanced stream extract.

## Principles
```
AuthSession (credentials may coexist)
├── web rail: Cookie + SAPISIDHASH → WEB browse / most players
└── tv  rail: Bearer (+ optional pageId) → TV browse / tv_downgraded player

Priority when both present:
  user-data / home: WEB first → else TV → else kiosk
  playback:        Cookie first → else OAuth+TV client → else anonymous mweb

Forbidden:
  Bearer on WEB FEwhat_to_watch
  stuffing access_token into Cookie fields
  clearing Cookie on successful device login (coexist instead)
```

## Phases

### P0 — Capability API
- AuthModels / AuthSessionManager capability bits
- Split getWebAuthorizationHeader / getTvAuthorizationHeader
- Device login keeps Cookie; signOut clears both

### P1 — Network inject by rail
- YouTubeHttpClient + YoutubeApi web vs tv headers/bodies
- fetchTvBrowsePage / prepareTvJsonBuilder

### P2 — Stream extract OAuth rail
- OAuth-only → tv_downgraded + Bearer
- hasAuthForPlaybackRequests

### P3 — Home TV recommended (done)
- browseId default + TV parse → VideoItem (`TvBrowseUtils`)
- HomeFeedService: web / tv / kiosk rails; sources recommended-web|recommended-tv|kiosk

### P4 — User data TV rail (done)
- UserLibraryService subscriptions/history/library/channels TV when OAuth-only

### P5 — UI / i18n / recovery (partial)
- authMode both; gate pages via hasAuthForUserData


## Verify
- devecocli build (full product)
- four account states: out / cookie / oauth / both
- log keys: authRail=, path=recommended-web|recommended-tv|kiosk
