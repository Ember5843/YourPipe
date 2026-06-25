# Quality Guidelines (Entry Module)

> Code standards, forbidden patterns, lint config.

---

## ArkTS strict type rules (project-wide)

These come from the repo `AGENTS.md` ArkTS rules and are non-negotiable:

- **No `any` or `unknown`** unless explicitly allowed by the user.
- **No `as` type assertions.**
- **No structural typing** — use explicit inheritance (`extends` / `implements`).
- **No dynamic property access** (e.g. `obj[dynamicKey]`).
- **Object literals must have explicit type context** (typed variable or typed function parameter).
- **No inline object literals for interfaces** — `arkts-no-untyped-obj-literals` forbids `{ method() {} }` to implement an interface. Create a named `class Foo implements Bar` instead (see `mediaservice/.../AvPlayerController.ets` `BackgroundTaskStateListener`, `PlayerSession.ets` `ContinueStateListener`).

If a third-party shape forces a cast, add an explicit interface and construct it; do not cast inline.

## Lint configuration

`code-linter.json5` applies to all `**/*.ets` (test/mock/build dirs ignored):

- `plugin:@performance/recommended`
- `plugin:@typescript-eslint/recommended`
- Security rules (all `error` unless noted):
  - `@security/no-unsafe-aes`, `-hash`, `-dh`, `-dsa`, `-ecdsa`, `-rsa-encrypt`, `-rsa-sign`,
    `-rsa-key`, `-dsa-key`, `-dh-key`, `-3des`
  - `@security/no-unsafe-mac` = `warn`

Before reporting a task done, ensure lint passes. Run `build_project` to confirm.

## Forbidden patterns

| Pattern | Why |
|---------|-----|
| ArkUI V2 decorators (`@ComponentV2`, `@Local`, `@Param`, `@ObservedV2`, `@Trace`, `@Monitor`, `@Computed`) | Project is V1-only; mixing breaks reactivity |
| `@BuilderParam` | Not used in this project |
| `router.pushUrl` / `router.replaceUrl` | Use `NavPathStack` |
| `any` / `as` casts | ArkTS strict typing |
| Direct mutation of `@StorageLink` object fields | UI won't refresh; clone→mutate→reassign |
| Missing `@Track` on `@Observed` fields used by list `@ObjectLink` | Scroll perf regression |
| Second `@Entry` page | Only `product/Index` is the entry |
| Hardcoded strings/colors | Use `$r` resources |
| Business logic in `build()` | Compute in members/services |
| `console.log` in shipped code | Use `common/AppLog.ets` facade |

## HarmonyOS API pitfalls

### `continuable: true` defaults to ACTIVE

When `module.json5` declares `continuable: true`, the system default `MissionContinueState` is **ACTIVE** from app launch.
If you want continuation only during specific states (e.g. playback), you MUST call
`context.setMissionContinueState(INACTIVE)` in `EntryAbility.onCreate` **before** UI loads — otherwise other nearby devices
see ACTIVE and pop continuation prompts on app entry. Then toggle ACTIVE/INACTIVE via a state listener
(see `PlayerSession.ContinueStateListener`). Never use `onForeground/onBackground` for this — they fire too late and
unconditionally.

### Continuation has TWO sides — do not delete either

`EntryAbility` has two continuation callbacks that look similar but serve opposite directions:

- **`onContinue(wantParam)`** — **sender side**. Called when the *other* device taps the continuation icon.
  Packs playback data via `PlaybackContinuationService.writeWantParam(wantParam)` and returns `AGREE`.
  Deleting it causes `[JUA1729] 'onContinue' is not implemented` and `OnContinue handle failed` (status 29360300).

- **`handleContinuationWant(want, launchParam)`** — **receiver side**. Called in `onCreate` AND `onNewWant`.
  Extracts the playback payload from the incoming Want and writes it to `AppStorage['pendingPlaybackContinuation']`.
  Has a `launchReason === CONTINUATION` guard so normal cold starts return early.
  `Index.ets:consumePendingPlaybackContinuation()` reads that key and jumps to the player page.
  Deleting it causes continuation to land on the receiver but only show the home page (no playback, no error toast).

Both must exist for end-to-end continuation. The `setMissionContinueState(INACTIVE)` in `onCreate` only controls
whether the continuation *icon* appears — it does not affect these callbacks.

### ShareKit `thumbnailUri` only accepts local file URIs

`systemShare.SharedData.thumbnailUri` (and `uri`) accept **only** app-sandbox file URIs (`fileUri.getUriFromPath(...)`)
or user-file URIs — **not** network URLs (`https://...`). For network thumbnails (e.g. YouTube images), pre-download to
`context.cacheDir` during `onVideoChange` and pass the local URI. Knock-share has a **3-second timeout**, so downloading
on-demand in the callback will fail — cache early, use the URI at share time.

### `fileIo` import name

`@kit.CoreFileKit` exports the file system module as `fileIo`, not `fs`. Import as:
`import { fileIo as fs } from '@kit.CoreFileKit';` (matches `DownloadManager.ets`, `Index.ets`, `AppLogStore.ets`).

### `http.request` typed result

`http.createHttp().request()` returns `result` typed as `Object` (can be string or ArrayBuffer). To satisfy ArkTS
no-`any` rules, pass `expectDataType: http.HttpDataType.ARRAY_BUFFER` and guard with `instanceof ArrayBuffer` before
writing to a file — do not use `as` casts.

## Logging

Use `common/AppLog.ets` (singleton `AppLog.getInstance()`), NOT raw `console`/`hilog`.
Centralizes log levels and format.

## Async

- Prefer `async/await` over raw `.then()` chains for readability.
- Wrap network/IO in try/catch; surface errors via the feature service's error model
  (see `common/model/ErrorInfo.ets`, `common/components/ErrorPage.ets`).
- Cancel in-flight requests in `aboutToDisappear` when a page is left.

## Constants

- Add app-wide constants to `common/constants/` (`CommonConstants`, `PageConstant`, etc.).
- Do not inline magic numbers/strings in components.

## Review checklist (for `trellis-check`)

- [ ] Types explicit on all `@State`/`@Prop`/`@Provide`/`@Consume`/`@StorageLink`
- [ ] No V2 decorators, no `@BuilderParam`, no `router.*`
- [ ] No `any`/`as`; object literals typed
- [ ] `@Observed` classes used by lists have `@Track` on consumed fields
- [ ] `AppStorage` config mutations use clone→mutate→reassign
- [ ] New components in `common/components/` are genuinely shared (2+ callers)
- [ ] Logging via `AppLog`; no `console.*`
- [ ] `build_project` succeeds

## Pitfalls (learned the hard way)

### `continuable: true` defaults to ACTIVE — set INACTIVE early

When `module.json5` declares `"continuable": true`, the system **defaults the mission continue state to `ACTIVE`**. If the app does not call `setMissionContinueState(INACTIVE)` before the UI loads, other nearby devices will show the continuation prompt as soon as the app launches.

**Fix**: call `context.setMissionContinueState(AbilityConstant.ContinueState.INACTIVE)` in `EntryAbility.onCreate` at the very top (before `onWindowStageCreate`), then let the playback state listener flip it to `ACTIVE` only during playback. See `EntryAbility.ets` onCreate + `PlayerSession.ets` `ContinueStateListener`.

### ShareKit `thumbnailUri` only accepts local file URIs

`systemShare.SharedData.thumbnailUri` (and `uri`) **do not accept network URLs** (e.g. `https://i.ytimg.com/...`). Passing a network URL silently results in a card with no preview image — only the app icon, title, and description show.

**Fix**: pre-download the image to `context.cacheDir` (or `filesDir`), then convert with `fileUri.getUriFromPath(localPath)` before passing to `SharedData`. Download early (e.g. on video change) so it's ready before the user triggers knock-share — the knock-share callback has a **3-second timeout**.

### `fileIo` import alias — not `fs`

`@kit.CoreFileKit` exports the file IO module as `fileIo`, **not** `fs`. Import with an alias:

```typescript
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
```

### `http.request` return type — use `expectDataType`

`http.createHttp().request()` returns `result: void | string | ArrayBuffer | object` by default, which triggers `arkts-no-any-unknown`. Pass `expectDataType: http.HttpDataType.ARRAY_BUFFER` (or `STRING`) so the return type is narrowed:

```typescript
const data = await downloader.request(url, {
  expectDataType: http.HttpDataType.ARRAY_BUFFER,
  ...
});
if (data.result instanceof ArrayBuffer) { ... }
```

