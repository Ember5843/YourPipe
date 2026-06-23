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
