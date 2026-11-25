/* Run: node tools/tests/interaction-regressions.cjs --typescript <DevEco TypeScript lib/typescript.js>
 * Executes the actual ArkTS service sources with deterministic platform adapters.
 * These tests exercise out-of-order completions; they do not replace device tests.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const tsArgument = process.argv.indexOf('--typescript');
const tsPath = tsArgument >= 0 ? process.argv[tsArgument + 1] : process.env.DEVECO_TYPESCRIPT_PATH;
if (!tsPath) throw new Error('Supply --typescript or DEVECO_TYPESCRIPT_PATH');
const ts = require(tsPath);
const root = path.resolve(__dirname, '../..');
const log = { getInstance: () => ({ debug() {}, info() {}, warn() {}, error() {} }) };
const loggerModule = { AppLog: log, YTCoreLogger: log };
function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}
function loader(adapters = {}, runtime = {}) {
  const modules = new Map();
  return function load(relative) {
    const file = path.resolve(root, relative);
    if (modules.has(file)) return modules.get(file).exports;
    const mod = { exports: {} };
    modules.set(file, mod);
    const source = ts.transpileModule(fs.readFileSync(file, 'utf8').replace(/^\s*@Concurrent\s*$/gm, ''), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020,
        experimentalDecorators: true }
    }).outputText;
    const requireSource = (request) => {
      if (Object.hasOwn(adapters, request)) return adapters[request];
      if (/\/(AppLog|YTCoreLogger)$/.test(request)) return loggerModule;
      if (request.startsWith('.')) return load(path.relative(root, path.resolve(path.dirname(file), request + '.ets')));
      throw new Error('Missing platform adapter: ' + request);
    };
    const run = vm.runInThisContext('(function(require,module,exports,setTimeout,clearTimeout,Observed,Track,$r,AppStorage){' + source + '\n})', { filename: file });
    run(requireSource, mod, mod.exports, runtime.setTimeout ?? setTimeout, runtime.clearTimeout ?? clearTimeout,
      value => value, () => {}, value => value, runtime.AppStorage);
    return mod.exports;
  };
}
function authFixture() {
  const values = new Map();
  const storage = { getSync: (k, d) => values.get(k) ?? d, putSync: (k, v) => values.set(k, v),
    flush: () => Promise.resolve(), flushSync() {} };
  class Downloader {
    constructor(observe = true) { this.observe = observe; }
    static setSetCookieObserver() {}
    static setAccountRevisionProvider() {}
    async request() { throw new Error('network offline'); }
  }
  const load = loader({ '@kit.ArkData': { preferences: { getPreferencesSync: () => storage } },
    './SmartTubeAuthProbe': { SmartTubeAuthProbe: class {} },
    './SapisidHashUtil': { SapisidHashUtil: { generate: async () => 'test-authorization' } },
    '../network/HttpDownloader': { HttpDownloader: Downloader },
    '../network/CookieJar': { splitSetCookieHeader: (v) => [v] } });
  const { AuthSessionManager } = load('youtube_core/src/main/ets/auth/AuthSessionManager.ets');
  const session = new AuthSessionManager({});
  const { CookieAuthCredential } = load('youtube_core/src/main/ets/auth/CookieAuthCredential.ets');
  const cookie = (id) => CookieAuthCredential.fromCookies('SID=' + id + '; SAPISID=' + id);
  return { session, cookie, storage, Downloader };
}

test('failed candidate verification preserves Cookie, OAuth and private-mode preference', async () => {
  const { session, cookie } = authFixture();
  session.saveCookieCredential(cookie('old'));
  session.refreshToken = 'old-refresh';
  session.setAuthEnabled(false);
  const revision = session.getCredentialRevision();
  await assert.rejects(session.verifyCookieCredential(cookie('candidate')), /network offline/);
  assert.equal(session.cookieCredential.cookies, cookie('old').cookies);
  assert.equal(session.refreshToken, 'old-refresh');
  assert.equal(session.authEnabled, false);
  assert.equal(session.getCredentialRevision(), revision);
});

test('credential disk failure cannot publish candidate account', () => {
  const { session, cookie, storage } = authFixture();
  session.saveCookieCredential(cookie('old'));
  const revision = session.getCredentialRevision();
  storage.flushSync = () => { throw new Error('disk full'); };
  assert.throws(() => session.saveCookieCredential(cookie('candidate')), /Unable to save/);
  assert.equal(session.cookieCredential.cookies, cookie('old').cookies);
  assert.equal(session.getCredentialRevision(), revision);
});

test('late token refresh success and invalid_grant cannot alter replacement account', async () => {
  for (const result of [{ accessToken: 'late', refreshToken: '', expiresIn: 3600, error: '' },
    { error: 'invalid_grant' }]) {
    const { session, cookie } = authFixture();
    session.refreshToken = 'old-refresh';
    const pending = deferred();
    session.probe.refreshAccessToken = () => pending.promise;
    const task = session.refreshAccessToken();
    session.signOut();
    session.saveCookieCredential(cookie('new'));
    pending.resolve(result);
    await task;
    assert.equal(session.accessToken, '');
    assert.equal(session.cookieCredential.cookies, cookie('new').cookies);
    assert.equal(session.consumeAuthRejectionNotice(), false);
  }
});

test('cancel while requesting device code cannot restart login polling', async () => {
  const { session } = authFixture();
  const pending = deferred();
  session.probe.requestDeviceCode = () => pending.promise;
  const task = session.startDeviceLogin();
  session.cancelDeviceLogin();
  pending.resolve({ deviceCode: 'late', userCode: 'late', expiresIn: 3600 });
  await task;
  assert.equal(session.deviceFlowActive, false);
  assert.equal(session.deviceCode, '');
});

test('old playlist page cannot append to replacement queue or clear its loading state', async () => {
  const pending = deferred();
  const newer = deferred();
  let call = 0;
  const load = loader({ youtube_core: {}, '../../common/FeedServiceProvider': {
    FeedServiceProvider: { getInstance: () => ({ getPlaylistService: () => ({
      fetchPlaylistNext: () => (++call === 1 ? pending.promise : newer.promise)
    }) }) } } });
  const { PlayQueueManager } = load('entry/src/main/ets/features/player/PlayQueueManager.ets');
  const queue = new PlayQueueManager();
  const a = { videoId: 'a' }, b = { videoId: 'b' };
  queue.setRemotePlaylistSnapshot('a', [a], 'a', 'a', 0, 'token-a');
  const task = queue.loadMore();
  queue.setRemotePlaylistSnapshot('b', [b], 'b', 'b', 0, 'token-b');
  const current = queue.loadMore();
  pending.resolve({ items: [{ videoId: 'stale' }], nextPageToken: 'stale' });
  assert.equal(await task, false);
  assert.equal(queue.isLoadingNextPage, true);
  assert.deepEqual(queue.queue, [b]);
  newer.resolve({ items: [{ videoId: 'b2' }], nextPageToken: null });
  assert.equal(await current, true);
  assert.deepEqual(queue.queue.map(v => v.videoId), ['b', 'b2']);
});

test('proxy enabled but unavailable fails closed; IPv6 loopback stays local', () => {
  const load = loader({ '@kit.ArkTS': { url: { URL: { parseURL: (value) => new URL(value) } } } });
  const { HttpProxyOptions, ProxyUnavailableError } = load('youtube_core/src/main/ets/network/HttpProxyOptions.ets');
  const snapshot = { kind: 'socks5', host: 'proxy.test', port: 1080, username: '', password: '', exclusionList: [], state: 'blocked' };
  assert.throws(() => HttpProxyOptions.assertAvailable('https://www.youtube.com', snapshot), ProxyUnavailableError);
  assert.doesNotThrow(() => HttpProxyOptions.assertAvailable('http://[::1]:5000', snapshot));
  assert.equal(HttpProxyOptions.shouldBypass('https://[2001:db8::1]', snapshot), false);
  snapshot.state = 'ready';
  assert.throws(() => HttpProxyOptions.assertAvailable('https://www.youtube.com', snapshot, true), ProxyUnavailableError);
  snapshot.socks5LocalPort = 12345;
  assert.doesNotThrow(() => HttpProxyOptions.assertAvailable('https://www.youtube.com', snapshot, true));
});

function controllerFixture() {
  const file = 'mediaservice/src/main/ets/controller/AvPlayerController.ets';
  const adapters = {};
  for (const match of fs.readFileSync(path.join(root, file), 'utf8').matchAll(/from\s+['"]([^'"]+)['"]/g)) {
    adapters[match[1]] = {};
  }
  const pending = new Map();
  const destroyed = [];
  const loads = [];
  adapters['./LocalMediaProxy'] = { LocalMediaProxy: {
    createSingleUrlSession: url => pending.get(url).promise,
    getPlaybackUrl: id => 'http://127.0.0.1:5555/' + id,
    destroySession: id => destroyed.push(id), markSessionStale() {}, updatePlaybackPosition() {}
  } };
  adapters['../utils/Logger'] = { default: log.getInstance() };
  adapters['../engine/VideoHwCaps'] = { VideoHwCaps: { isCodecHardwareFriendly: () => true } };
  const load = loader(adapters);
  const { AvPlayerController } = load(file);
  const owner = Object.create(AvPlayerController.prototype);
  const current = {};
  owner.vm = { isPlaying: true, currentTime: 42, playerModel: {
    updateVideoStream: v => current.video = v, updateAudioStream: a => current.audio = a
  } };
  Object.assign(owner, { mediaSessionGeneration: 1, sourceSwitchGeneration: 0, transportIntentRevision: 0,
    transportIntentPlaying: true, curSource: { isLive: false }, currentLocalMediaSessionId: '',
    currentEdlAudioSessionId: '', pendingDestroySessionId: '', pendingDestroyEdlAudioSessionId: '',
    currentHlsAudioUrl: '', stateMachine: { isOneOf: () => false } });
  owner.isActive = () => true;
  owner.isMediaSessionCurrent = g => g === owner.mediaSessionGeneration;
  owner.isSeparatedDash = () => false;
  owner.clearFocusInterruptFlags = () => {};
  owner.logDiagSnapshot = () => {};
  owner.avSessionManager = { deactivateForPause() {} };
  let plays = 0;
  owner.playbackEngine = { load: url => { loads.push(url); return true; },
    play: () => plays++, pause() {} };
  return { owner, pending, destroyed, loads, current, get plays() { return plays; } };
}

test('latest quality choice wins and stale preparation releases only its candidate', async () => {
  const f = controllerFixture();
  const a = { url: 'a', kind: 'progressive', height: 720 };
  const b = { url: 'b', kind: 'progressive', height: 1080 };
  f.pending.set('a', deferred());
  f.pending.set('b', deferred());
  const old = f.owner.switchQuality(a);
  const latest = f.owner.switchQuality(b);
  f.pending.get('b').resolve('session-b');
  await latest;
  f.pending.get('a').resolve('session-a');
  await old;
  assert.deepEqual(f.loads, ['http://127.0.0.1:5555/session-b']);
  assert.equal(f.current.video, b);
  assert.equal(f.owner.currentLocalMediaSessionId, 'session-b');
  assert.deepEqual(f.destroyed, ['session-a']);
});

test('pause during quality preparation prevents captured playing state from resuming', async () => {
  const f = controllerFixture();
  f.pending.set('a', deferred());
  const task = f.owner.switchQuality({ url: 'a', kind: 'progressive', height: 720 });
  f.owner.syncPause();
  f.pending.get('a').resolve('session-a');
  await task;
  assert.equal(f.loads.length, 1);
  assert.equal(f.plays, 0);
});

test('same-media reload publishes retained timeline without mutating engine snapshot', () => {
  const load = loader();
  const { normalizePlaybackTimeline } = load('mediaservice/src/main/ets/state/PlaybackTimeline.ets');
  const raw = { isReady: false, currentTime: 0, duration: 0 };
  const visible = normalizePlaybackTimeline(raw, 42, 100);
  assert.equal(visible.currentTime, 42);
  assert.equal(visible.duration, 100);
  assert.equal(raw.currentTime, 0);
  assert.equal(normalizePlaybackTimeline(raw, 0, 0), raw);
  const seeked = { ...raw, isReady: true };
  assert.equal(normalizePlaybackTimeline(seeked, 42, 100), seeked);
});

test('metadata persistence preserves product fields and drops derived enrichment flags', () => {
  const basic = loader();
  const core = basic('youtube_core/src/main/ets/common/VideoModel.ets');
  const load = loader({ youtube_core: core });
  const { VideoItemPersistence } = load('entry/src/main/ets/common/VideoItemPersistence.ets');
  const video = new core.VideoItem(1, 'v', 'title', 'author', '1', 'thumb', false);
  Object.assign(video, { isShort: true, durationText: '12:34', uploaderVerified: true,
    isPremium: true, requiresMembership: true, viewCountExact: '1234', localMediaPath: '/media.mp4', aiListFlag: 'block' });
  const restored = VideoItemPersistence.restore(JSON.parse(JSON.stringify(VideoItemPersistence.record(video))));
  for (const field of ['isShort', 'durationText', 'uploaderVerified', 'isPremium', 'requiresMembership', 'viewCountExact', 'localMediaPath']) {
    assert.equal(restored[field], video[field], field);
  }
  assert.equal(restored.aiListFlag, '');
  assert.equal(VideoItemPersistence.restore({ videoId: 'old' }).isShort, false);
});

test('search B owns results, continuation, errors and loading after search A finishes late', async () => {
  const queries = new Map([['a', deferred()], ['b', deferred()], ['c', deferred()]]);
  const load = loader({ youtube_core: { AuthSessionManager: { getInstance: () => null } },
    '../../common/FeedServiceProvider': { FeedServiceProvider: { getInstance: () => ({
      getSearchService: () => ({ setFilters() {}, searchInitial: q => queries.get(q).promise })
    }) } }, '../../common/model/FeedDataSource': { FeedDataSource: class { setData(items) { this.items = items; } } } });
  const { SearchViewModel } = load('entry/src/main/ets/features/search/SearchViewModel.ets');
  const state = new SearchViewModel();
  state.activate();
  const a = state.search('a', [], true);
  const b = state.search('b', [], true);
  queries.get('a').reject(new Error('late failure'));
  await a;
  assert.equal(state.isSearching, true);
  assert.equal(state.errorMessage, '');
  queries.get('b').resolve({ items: [{ id: 2 }], nextPageToken: 'b-next' });
  await b;
  assert.equal(state.results[0].id, 2);
  assert.equal(state.nextPageToken, 'b-next');
  const c = state.search('c', [], true);
  state.deactivate();
  queries.get('c').resolve({ items: [{ id: 3 }], nextPageToken: 'c-next' });
  await c;
  assert.equal(state.results.length, 0);
  assert.equal(state.isSearching, false);
});

test('restore fence rejects requests started before and during recovery', () => {
  const { AppDataEpoch } = loader()('entry/src/main/ets/common/AppDataEpoch.ets');
  const before = AppDataEpoch.capture();
  const lease = AppDataEpoch.beginRecovery();
  const during = AppDataEpoch.capture();
  assert.equal(AppDataEpoch.isCurrent(before), false);
  assert.equal(AppDataEpoch.isCurrent(during), false);
  assert.throws(() => AppDataEpoch.beginRecovery(), /already running/);
  AppDataEpoch.finishRecovery(lease);
  assert.equal(AppDataEpoch.isCurrent(during), false);
  assert.equal(AppDataEpoch.isCurrent(AppDataEpoch.capture()), true);
});

function downloadFixture(overrides = {}) {
  const file = 'entry/src/main/ets/common/DownloadManager.ets';
  const adapters = {};
  for (const match of fs.readFileSync(path.join(root, file), 'utf8').matchAll(/from\s+['"]([^'"]+)['"]/g)) adapters[match[1]] = {};
  adapters['./AppLog'] = loggerModule;
  Object.assign(adapters, overrides);
  const { DownloadManager, DownloadTask, DownloadStatus } = loader(adapters)(file);
  const manager = Object.create(DownloadManager.prototype);
  Object.assign(manager, { tasks: [], activeTaskIds: new Set(), runningTasks: new Map(), clearingTasks: false });
  manager.startWatchdog = manager.stopWatchdog = manager.notifyTasksChanged = manager.cancelDownloadNotification = () => {};
  manager.getMaxConcurrentDownloads = () => 1;
  return { manager, DownloadTask, DownloadStatus };
}

test('pause/resume keeps old attempt cancelled until its file owner exits', async () => {
  const { manager, DownloadTask, DownloadStatus } = downloadFixture();
  const task = new DownloadTask('task', 'video', 'title', '', '', { url: 'old' }, null);
  manager.tasks = [task];
  const old = deferred();
  let executions = 0;
  manager.executeTask = async () => {
    executions++;
    if (executions === 1) {
      task.status = DownloadStatus.DOWNLOADING_VIDEO;
      await old.promise;
      assert.equal(task._cancelled, true);
      assert.equal(task.videoStream.url, 'old');
    } else {
      assert.equal(task.videoStream.url, 'new');
      task.status = DownloadStatus.COMPLETED;
    }
  };
  manager.processQueue();
  let aborts = 0;
  task._abortHandlers.add(() => aborts++);
  assert.equal(manager.pauseTask(task.id), true);
  assert.equal(aborts, 1);
  assert.equal(manager.resumeTask(task.id, { url: 'new' }), true);
  assert.equal(task._cancelled, true);
  assert.equal(executions, 1);
  old.resolve();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(executions, 2);
  assert.equal(task._attemptId, 2);
  assert.equal(task.status, DownloadStatus.COMPLETED);
});

test('clear waits for download owner before deleting its files', async () => {
  const { manager, DownloadTask, DownloadStatus } = downloadFixture();
  const task = new DownloadTask('task', 'video', 'title', '', '', { url: 'old' }, null);
  manager.tasks = [task];
  const old = deferred();
  let cleaned = false;
  manager.cleanupTaskFiles = () => { cleaned = true; };
  manager.executeTask = async () => {
    task.status = DownloadStatus.MERGING;
    await old.promise;
    assert.equal(cleaned, false);
    assert.equal(task._cancelled, true);
  };
  manager.processQueue();
  const cleared = manager.clearAllTasksAndFiles();
  assert.equal(cleaned, false);
  old.resolve();
  await cleared;
  assert.equal(cleaned, true);
  assert.equal(manager.tasks.length, 0);
});

test('stalled HTTP download aborts without waiting for a byte or timeout', async () => {
  const events = new Map();
  let destroyed = 0, written = 0;
  const request = { on: (key, fn) => events.set(key, fn), off() {},
    requestInStream: () => new Promise(() => {}), destroy: () => destroyed++ };
  const { manager, DownloadTask } = downloadFixture({
    '@kit.NetworkKit': { http: { createHttp: () => request, RequestMethod: { GET: 'GET' } } },
    '@kit.CoreFileKit': { fileIo: { writeSync: () => written++ } },
    youtube_core: { HttpDownloader: { applyProxyToOptions() {} } }
  });
  const task = new DownloadTask('task', 'v', '', '', '', {}, null);
  const reading = manager.requestStreamToFile('https://example.test', {}, { fd: 1 }, task, () => {});
  task.abortAttempt();
  await assert.rejects(reading, /cancelled/);
  events.get('dataReceive')(new ArrayBuffer(100));
  assert.equal(destroyed, 1);
  assert.equal(written, 0);
  assert.equal(task._abortHandlers.size, 0);
});

test('candidate success is isolated from active credentials and account-cookie observer', async () => {
  const { session, cookie, Downloader } = authFixture();
  session.saveCookieCredential(cookie('old'));
  Downloader.prototype.request = async function () {
    assert.equal(this.observe, false);
    return { responseCode: 200, result: JSON.stringify({ contents: {},
      responseContext: { mainAppWebResponseContext: { loggedOut: false } } }) };
  };
  await session.verifyCookieCredential(cookie('candidate'));
  assert.equal(session.cookieCredential.cookies, cookie('old').cookies);
});

test('cleared prefetch cannot refill caches or delete a newer in-flight task', async () => {
  const file = 'entry/src/main/ets/features/player/YouTubePlayService.ets';
  const adapters = {};
  for (const match of fs.readFileSync(path.join(root, file), 'utf8').matchAll(/from\s+['"]([^'"]+)['"]/g)) adapters[match[1]] = {};
  adapters['../../common/AppLog'] = loggerModule;
  adapters.youtube_core = { AuthSessionManager: { getInstance: () => null },
    YoutubePlayerClientConfig: { getConfigurationKey: () => 'endpoints' } };
  const { YouTubePlayService } = loader(adapters)(file);
  const service = Object.create(YouTubePlayService.prototype);
  Object.assign(service, { prefetchedResults: new Map(), prefetchInFlight: new Map(),
    dashPotInjections: new Map(), prefetchGeneration: 0 });
  const old = deferred(), fresh = deferred();
  let calls = 0;
  service.play = () => (++calls === 1 ? old.promise : fresh.promise);
  service.prefetch('video');
  service.clearPrefetchCache();
  service.prefetch('video');
  old.resolve({ success: true });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(service.prefetchedResults.size, 0);
  assert.equal(service.prefetchInFlight.size, 1);
  fresh.resolve({ success: true, playerStreams: [] });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(service.prefetchedResults.size, 1);
});

function proxyFixture() {
  const basics = loader({ '@kit.ArkTS': { url: { URL: { parseURL: value => new URL(value) } } } });
  const core = basics('youtube_core/src/main/ets/network/HttpProxyOptions.ets');
  const callbacks = [], timers = new Map(), routes = [];
  let timerSequence = 0;
  const values = new Map();
  core.socks5Bridge = { stop() {}, getPort: () => 0, isRunning: () => false, isFuseBlown: () => false,
    setPortChangeListener() {}, setFailureListener() {}, blockRequests: async () => 5555 };
  const load = loader({ youtube_core: core, './PreferencesStore': {},
    '@kit.NetworkKit': { connection: { setAppHttpProxy: p => routes.push(p) } },
    '@kit.ArkWeb': { webview: { ProxyConfig: class { insertProxyRule() {} },
      ProxySchemeFilter: { MATCH_ALL_SCHEMES: 0 }, ProxyController: {
        applyProxyOverride: (_, cb) => callbacks.push(cb), removeProxyOverride: cb => callbacks.push(cb)
      } } } }, { AppStorage: { has: key => values.has(key), setOrCreate: (k, v) => values.set(k, v), get: k => values.get(k) },
    setTimeout: fn => { const id = ++timerSequence; timers.set(id, fn); return id; }, clearTimeout: id => timers.delete(id) });
  const { NetworkProxyConfig } = load('entry/src/main/ets/common/NetworkProxyConfig.ets');
  const config = new NetworkProxyConfig();
  Object.assign(config, { enabled: true, kind: 'http', host: 'proxy.test', port: 8080 });
  return { NetworkProxyConfig, config, core, callbacks, timers, routes };
}

test('proxy readiness waits for native callback and uses a copied config', async () => {
  const f = proxyFixture();
  const task = f.NetworkProxyConfig.applySystemAndProviders(f.config);
  f.config.host = 'mutated.test';
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.NetworkProxyConfig.getStatus().state, 'applying');
  assert.equal(f.core.HttpProxyOptions.getSnapshot().host, 'proxy.test');
  assert.throws(() => f.core.HttpProxyOptions.assertAvailable('https://www.youtube.com'), /unavailable/);
  f.callbacks.shift()();
  await task;
  assert.equal(f.NetworkProxyConfig.getStatus().state, 'ready');
  assert.equal(f.routes[0].host, 'proxy.test');
});

test('missing native proxy callback leaves blocked state and installs refusing loopback route', async () => {
  const f = proxyFixture();
  const task = f.NetworkProxyConfig.applySystemAndProviders(f.config);
  const rejected = assert.rejects(task, /unavailable/);
  await new Promise(resolve => setImmediate(resolve));
  [...f.timers.values()][0]();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.NetworkProxyConfig.getStatus().state, 'blocked');
  assert.equal(f.routes[0].host, '127.0.0.1');
  f.callbacks.pop()();
  await rejected;
  assert.throws(() => f.core.HttpProxyOptions.assertAvailable('https://www.youtube.com'), /unavailable/);
});

test('settings writes share a flush and completion propagates disk errors', async () => {
  const writes = new Map();
  let flushes = 0;
  const disk = deferred();
  const storage = { putSync: (k, v) => writes.set(k, v), flush: () => { flushes++; return disk.promise; } };
  const load = loader({ '@kit.ArkData': { preferences: { getPreferencesSync: () => storage } } });
  const { PreferencesStore } = load('entry/src/main/ets/common/PreferencesStore.ets');
  PreferencesStore.init({});
  PreferencesStore.setString('cfg_a', 'a');
  PreferencesStore.setString('cfg_b', 'b');
  const result = assert.rejects(PreferencesStore.flushPending(), /disk full/);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(flushes, 1);
  assert.equal(writes.size, 2);
  disk.reject(new Error('disk full'));
  await result;
});

test('clearing imported media waits for pending copy and removes its uncommitted file', async () => {
  const copying = deferred();
  const removed = [];
  const values = new Map([['context', { filesDir: '/app/files' }], ['localMedia', []]]);
  const load = loader({ '@kit.CoreFileKit': { fileIo: { accessSync: () => false, mkdirSync() {},
    stat: async () => ({ size: 100 }), copyFile: () => copying.promise, unlink: async p => removed.push(p) } },
    youtube_core: {}, './PreferencesStore': { PreferencesStore: { setString() {} } },
    './LocalMediaProgressStore': { LocalMediaProgressStore: { remove() {} } } },
    { AppStorage: { get: k => values.get(k), setOrCreate: (k, v) => values.set(k, v) } });
  const { LocalMediaStore } = load('entry/src/main/ets/common/LocalMediaStore.ets');
  const imported = LocalMediaStore.importFromUris(['/picker/video.mp4']);
  await new Promise(resolve => setImmediate(resolve));
  let cleared = false;
  const clearing = LocalMediaStore.clearAll().then(() => cleared = true);
  assert.equal(cleared, false);
  copying.resolve();
  await Promise.all([imported, clearing]);
  assert.equal(values.get('localMedia').length, 0);
  assert.equal(removed.length, 1);
  assert.match(removed[0], /^\/app\/files\/local_media\/imp_/);
});

test('HLS URL resolution handles protocol-relative paths, parent paths, query strings and IPv6', () => {
  const { manager } = downloadFixture({ '@kit.ArkTS': { url: { URL: { parseURL: (ref, base) => new URL(ref, base) } } } });
  const base = 'https://[2001:db8::1]/a/b/master.m3u8?old=/query';
  for (const [ref, expected] of [
    ['//cdn.test/video.ts', 'https://cdn.test/video.ts'],
    ['../video.ts', 'https://[2001:db8::1]/a/video.ts'],
    ['?token=x/y', 'https://[2001:db8::1]/a/b/master.m3u8?token=x/y'],
    ['/video.ts', 'https://[2001:db8::1]/video.ts']
  ]) assert.equal(manager.resolveHlsUrl(ref, base), expected);
});

test('replacing one Cookie account with another resets visitor and PoToken caches', () => {
  let revision = 0, identityResets = 0, tokenResets = 0;
  const session = { getStatus: () => ({}), hasWebSapisidStored: () => true,
    hasOauthCredentialStored: () => false, getCredentialRevision: () => revision,
    isAuthEnabledForPlayback: () => true };
  const load = loader({ youtube_core: { AuthSessionManager: { getInstance: () => session },
    YoutubeJavaScriptPlayerManager: { resetSessionVisitorData: () => identityResets++ } },
    '@ohos.web.webview': {}, '../features/player/SabrWebViewPoTokenProvider': {
      SabrWebViewPoTokenProvider: { getInstance: () => ({ resetForAuthChange: () => tokenResets++, warmRuntime() {} }) }
    } }, { AppStorage: { setOrCreate() {} } });
  const { AuthStateHelper } = load('entry/src/main/ets/common/AuthStateHelper.ets');
  AuthStateHelper.refresh();
  assert.equal(identityResets, 0);
  revision++;
  AuthStateHelper.refresh();
  assert.equal(identityResets, 1);
  assert.equal(tokenResets, 1);
  AuthStateHelper.refresh();
  assert.equal(identityResets, 1);
});
