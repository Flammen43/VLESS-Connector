// Тесты настоящего extension/background.js с подставным chrome.*.
// Запуск: node tests/js/background.test.js (или в любом V8 — см. runBackgroundTests).
//
// Здесь проверяется то, что нельзя проверить на чистых функциях: порядок действий
// при обрыве соединения, переключатель LAN, версия хоста, очистка остатков убранных опций.

async function runBackgroundTests(src, assert) {
  const eq = (a, b, msg) => assert(JSON.stringify(a) === JSON.stringify(b), `${msg}: ждали ${JSON.stringify(b)}, получили ${JSON.stringify(a)}`);

  /** Новый «браузер»: хранилище, прокси, политика, значок и скриптуемый Native Host. */
  function makeEnv({ storage = {}, session = {}, privacy = false, hostVersion = '1.1.0', proxy = null, policy = null } = {}) {
    const env = {
      store: { ...storage }, session: { ...session }, proxy, policy,
      badge: { text: '', color: '' }, xrayAlive: true, hostVersion, hostCalls: [],
    };
    const matches = (store, keys) => {
      if (keys == null) return { ...store };
      const list = Array.isArray(keys) ? keys : (typeof keys === 'string' ? [keys] : Object.keys(keys));
      const out = {};
      for (const k of list) if (k in store) out[k] = store[k];
      return out;
    };
    const area = (store) => ({
      get: async (keys) => matches(store, keys),
      set: async (obj) => { Object.assign(store, obj); },
      remove: async (keys) => { for (const k of [].concat(keys)) delete store[k]; },
    });
    const host = (m) => {
      env.hostCalls.push(m.action);
      if (m.action === 'start') return { success: true, port: 10808 };
      if (m.action === 'status') {
        const r = { success: true, data: env.xrayAlive ? 'running' : 'stopped' };
        if (env.hostVersion != null) r.hostVersion = env.hostVersion;   // null — старый хост без поля
        return r;
      }
      if (m.action === 'ping') return env.xrayAlive ? { success: true, pingMs: 1 } : { success: false, error: 'refused' };
      return { success: true };
    };
    const chrome = {
      runtime: {
        lastError: undefined,
        getManifest: () => ({ version: '1.1.0' }),
        onMessage: { addListener() {} },
        onInstalled: { addListener() {} },
        connectNative() {
          const listeners = [];
          return {
            onMessage: { addListener: (f) => listeners.push(f), removeListener() {} },
            onDisconnect: { addListener() {}, removeListener() {} },
            postMessage(m) { const r = { ...host(m), id: m.id }; setTimeout(() => listeners.forEach(f => f(r)), 0); },
            disconnect() {},
          };
        },
      },
      storage: { local: area(env.store), session: area(env.session) },
      proxy: { settings: {
        set: (a, cb) => { env.proxy = a.value; cb(); },
        clear: (a, cb) => { env.proxy = null; cb(); },
      } },
      action: {
        setBadgeText: ({ text }) => { env.badge.text = text; },
        setBadgeBackgroundColor: ({ color }) => { env.badge.color = color; },
      },
      alarms: { create() {}, clear() {}, onAlarm: { addListener() {} } },
    };
    if (privacy) {
      chrome.privacy = { network: { webRTCIPHandlingPolicy: {
        set: (a, cb) => { env.policy = a.value; cb(); },
        clear: (a, cb) => { env.policy = null; cb(); },
      } } };
    }
    return { env, chrome };
  }

  async function boot(opts) {
    const { env, chrome } = makeEnv(opts);
    const api = new Function('chrome', 'importScripts', 'crypto',
      `${src.proxyRules}\n${src.compat}\n${src.background}\n` +
      'return { handleMessage, runKillSwitchCheck, initDone };')(chrome, () => {}, { randomUUID: () => 'client-1' });
    await api.initDone;
    return { env, api, send: (m) => api.handleMessage(m) };
  }
  const connect = (t) => t.send({ action: 'connect', vlessUrl: 'vless://u@h.example:443', config: { protocol: 'vless' } });
  const kill = async (t) => { t.env.xrayAlive = false; return t.api.runKillSwitchCheck({ immediate: true }); };

  // ── подключение ────────────────────────────────────────────
  let t = await boot();
  eq((await connect(t)).success, true, 'подключение успешно');
  eq(t.env.proxy.rules.singleProxy.port, 10808, 'прокси указывает на SOCKS Xray');
  assert(t.env.proxy.rules.bypassList.includes('192.168.0.0/16'), 'LAN в списке обхода по умолчанию');
  eq(t.env.badge.text, 'ON', 'значок ON');
  eq((await t.send({ action: 'disconnect' })).success, true, 'отключение');
  eq(t.env.proxy, null, 'после отключения прокси снят');

  // ── обрыв: прокси снят, но пользователь предупреждён ───────
  t = await boot();
  await connect(t);
  const r1 = await kill(t);
  eq(r1.tripped, true, 'kill-switch сработал');
  eq(t.env.proxy, null, 'прокси снят');
  assert(t.env.store.connectionDropped > 0, 'записана метка обрыва для сообщения в окне');
  eq(t.env.badge.text, '!', 'значок «!»');
  eq(t.env.badge.color, '#f59e0b', 'значок оранжевый (трафик идёт напрямую)');
  eq(t.env.store.isConnected, false, 'состояние «отключено»');
  await t.send({ action: 'ackDrop' });
  assert(!('connectionDropped' in t.env.store), 'ackDrop снимает метку');
  eq(t.env.badge.text, 'OFF', 'после ackDrop значок OFF');

  // повторное подключение после обрыва убирает метку
  t = await boot();
  await connect(t); await kill(t);
  t.env.xrayAlive = true;
  await connect(t);
  assert(!('connectionDropped' in t.env.store), 'успешное подключение убирает метку обрыва');
  eq(t.env.badge.text, 'ON', 'значок снова ON');

  // ── переключатель «локальная сеть напрямую» ───────────────
  t = await boot();
  await connect(t);
  t.env.store.lanDirect = false;
  eq((await t.send({ action: 'refreshProxy' })).applied, true, 'refreshProxy применён при подключении');
  assert(!t.env.proxy.rules.bypassList.includes('192.168.0.0/16'), 'LAN выключен — в обходе только loopback');
  t.env.store.lanDirect = true;
  await t.send({ action: 'refreshProxy' });
  assert(t.env.proxy.rules.bypassList.includes('192.168.0.0/16'), 'LAN включён — диапазоны в обходе');
  await t.send({ action: 'disconnect' });
  eq((await t.send({ action: 'refreshProxy' })).applied, false, 'без подключения refreshProxy ничего не меняет');
  eq(t.env.proxy, null, 'и не поднимает прокси сам');

  // ── остатки убранных опций (блокировка трафика, WebRTC) ───
  // Кто-то мог запустить сборку, где они были: прокси стоит на порту-заглушке.
  const stale = { rules: { singleProxy: { scheme: 'socks5', host: '127.0.0.1', port: 1 }, bypassList: [] } };
  t = await boot({ privacy: true, proxy: stale, policy: 'disable_non_proxied_udp',
    storage: { blocked: true, webrtcProtect: true, killSwitchStrict: true } });
  eq(t.env.proxy, null, 'прокси на порту-заглушке снят при старте');
  eq(t.env.policy, null, 'политика WebRTC снята');
  assert(!('blocked' in t.env.store) && !('webrtcProtect' in t.env.store) && !('killSwitchStrict' in t.env.store), 'ключи убранных опций удалены');

  // Живое соединение при этом не трогаем (только политика/ключи)
  t = await boot({ privacy: true, policy: 'disable_non_proxied_udp', session: { swAlive: true },
    storage: { isConnected: true, socksPort: 10808, clientId: 'client-1', webrtcProtect: true } });
  eq(t.env.proxy && t.env.proxy.rules.singleProxy.port, 10808, 'активное подключение восстановлено, а не сброшено');
  eq(t.env.store.isConnected, true, 'isConnected сохранён');
  assert(!t.env.hostCalls.includes('stop'), 'Xray не останавливается');
  eq(t.env.policy, null, 'но политика WebRTC убрана');
  assert(!('webrtcProtect' in t.env.store), 'ключ webrtcProtect удалён');

  // без остатков ничего лишнего не происходит
  t = await boot();
  eq(t.env.hostCalls.filter(a => a === 'stop').length, 0, 'чистый старт не останавливает хост');

  // ── версия хоста ──────────────────────────────────────────
  t = await boot({ hostVersion: '1.1.0' });
  let v = await t.send({ action: 'hostVersion' });
  eq([v.success, v.ok, v.kind], [true, true, 'ok'], 'версии совпадают');
  t = await boot({ hostVersion: null });
  v = await t.send({ action: 'hostVersion' });
  eq([v.success, v.ok, v.kind, v.hostVersion], [true, false, 'old', null], 'хост без версии считается старым');
  assert(/установщик/.test(v.message), 'и сообщение говорит про установщик');
  t = await boot({ hostVersion: '1.2.0' });
  v = await t.send({ action: 'hostVersion' });
  eq(v.kind, 'newer', 'хост новее расширения');
}

if (typeof module !== 'undefined' && module.exports) {
  const fs = require('fs');
  const path = require('path');
  const read = (f) => fs.readFileSync(path.join(__dirname, '..', '..', 'extension', f), 'utf8');
  let failed = 0;
  runBackgroundTests(
    { proxyRules: read('proxy-rules.js'), compat: read('compat.js'), background: read('background.js') },
    (ok, msg) => { if (!ok) { failed++; console.error('FAIL: ' + msg); } }
  ).then(() => {
    console.log(failed ? `${failed} проверок не прошло` : 'ok');
    process.exit(failed ? 1 : 0);
  }).catch((e) => { console.error(e); process.exit(1); });
}
