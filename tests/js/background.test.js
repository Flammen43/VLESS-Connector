// Тесты настоящего extension/background.js с подставным chrome.*.
// Запуск: node tests/js/background.test.js (или в любом V8 — см. runBackgroundTests).
//
// Здесь проверяется то, что нельзя проверить на чистых функциях: порядок действий
// при обрыве соединения, строгая блокировка, политика WebRTC, версия хоста.

async function runBackgroundTests(src, assert) {
  const eq = (a, b, msg) => assert(JSON.stringify(a) === JSON.stringify(b), `${msg}: ждали ${JSON.stringify(b)}, получили ${JSON.stringify(a)}`);

  /** Новый «браузер»: хранилище, прокси, политика, значок и скриптуемый Native Host. */
  function makeEnv({ storage = {}, privacy = false, hostVersion = '1.1.0', startFails = false } = {}) {
    const env = {
      store: { ...storage }, session: {}, proxy: null, proxyCalls: 0,
      policy: null, badge: { text: '', color: '' }, xrayAlive: true, startFails, hostVersion, proxySetFails: false,
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
      if (m.action === 'start') return env.startFails ? { success: false, error: 'xray не запустился' } : { success: true, port: 10808 };
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
          const listeners = [], discon = [];
          return {
            onMessage: { addListener: (f) => listeners.push(f), removeListener() {} },
            onDisconnect: { addListener: (f) => discon.push(f), removeListener() {} },
            postMessage(m) { const r = { ...host(m), id: m.id }; setTimeout(() => listeners.forEach(f => f(r)), 0); },
            disconnect() {},
          };
        },
      },
      storage: { local: area(env.store), session: area(env.session) },
      proxy: { settings: {
        set: (a, cb) => {
          if (env.proxySetFails && a.value.rules.singleProxy.port !== 1) {   // рабочий прокси применить не удалось
            chrome.runtime.lastError = { message: 'доступ запрещён' }; cb(); chrome.runtime.lastError = undefined; return;
          }
          env.proxy = a.value; env.proxyCalls++; cb();
        },
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
  const isBlockConfig = (p) => !!p && p.rules.singleProxy.port === 1;

  // ── подключение ────────────────────────────────────────────
  let t = await boot();
  eq((await connect(t)).success, true, 'подключение успешно');
  eq(t.env.proxy.rules.singleProxy.port, 10808, 'прокси указывает на SOCKS Xray');
  assert(t.env.proxy.rules.bypassList.includes('192.168.0.0/16'), 'LAN в списке обхода по умолчанию');
  eq(t.env.badge.text, 'ON', 'значок ON');
  eq((await t.send({ action: 'disconnect' })).success, true, 'отключение');
  eq(t.env.proxy, null, 'после отключения прокси снят');

  // ── обрыв, обычный режим: прокси снят, но пользователь предупреждён ─
  t = await boot();
  await connect(t);
  const r1 = await kill(t);
  eq(r1.tripped, true, 'kill-switch сработал');
  eq(t.env.proxy, null, 'обычный режим: прокси снят');
  assert(t.env.store.connectionDropped > 0, 'записана метка обрыва для сообщения в окне');
  eq(t.env.badge.text, '!', 'значок «!»');
  eq(t.env.badge.color, '#f59e0b', 'значок оранжевый (трафик идёт напрямую)');
  assert(!t.env.store.blocked, 'блокировки нет');
  await t.send({ action: 'ackDrop' });
  assert(!('connectionDropped' in t.env.store), 'ackDrop снимает метку');
  eq(t.env.badge.text, 'OFF', 'после ackDrop значок OFF');

  // ── обрыв, строгий режим: трафик закрыт ────────────────────
  t = await boot({ storage: { killSwitchStrict: true } });
  await connect(t);
  await kill(t);
  assert(isBlockConfig(t.env.proxy), 'строгий режим: прокси «в никуда», а не снят');
  eq(t.env.store.blocked, true, 'флаг blocked записан');
  assert(!('proxyNeedsClear' in t.env.store) || t.env.store.proxyNeedsClear === false, 'proxyNeedsClear не взведён (иначе старт браузера откроет интернет)');
  eq(t.env.badge.color, '#ef4444', 'значок красный');
  const st = await t.send({ action: 'getStatus' });
  eq([st.isConnected, st.blocked], [false, true], 'getStatus сообщает о блокировке');
  assert(!('connectionDropped' in t.env.store), 'в строгом режиме «трафик идёт напрямую» не сообщаем');

  // ── из блокировки: неудачное подключение блокировку не снимает ─
  t.env.xrayAlive = true; t.env.startFails = true;
  let failed = false;
  try { await connect(t); } catch (e) { failed = true; }
  eq(failed, true, 'подключение не удалось');
  assert(isBlockConfig(t.env.proxy), 'после неудачного подключения блокировка на месте');
  eq(t.env.store.blocked, true, 'blocked по-прежнему true');

  // ── из блокировки: Xray стартовал, но применить прокси не удалось ─
  t.env.startFails = false; t.env.xrayAlive = true; t.env.proxySetFails = true;
  failed = false;
  try { await connect(t); } catch (e) { failed = true; }
  eq(failed, true, 'подключение не удалось (прокси не применился)');
  assert(isBlockConfig(t.env.proxy), 'cleanup после сбоя не оставляет интернет открытым: блокировка возвращена');
  eq(t.env.store.blocked, true, 'blocked снова true');
  t.env.proxySetFails = false;

  // ── из блокировки: перезапуск браузера/worker не открывает интернет ─
  const fresh = await boot({ storage: { ...t.env.store } });
  assert(isBlockConfig(fresh.env.proxy), 'после перезапуска worker блокировка восстановлена');
  eq(fresh.env.badge.text, '!', 'значок «!» после перезапуска');

  // ── из блокировки: успешное подключение заменяет блокировку ─
  t.env.startFails = false;
  await connect(t);
  eq(t.env.proxy.rules.singleProxy.port, 10808, 'рабочий прокси вместо блокирующего');
  eq(t.env.store.blocked, false, 'blocked сброшен');

  // ── снятие блокировки без подключения ─────────────────────
  t = await boot({ storage: { killSwitchStrict: true } });
  await connect(t); await kill(t);
  assert(isBlockConfig(t.env.proxy), 'предусловие: заблокировано');
  await t.send({ action: 'unblock' });
  eq(t.env.proxy, null, 'unblock снимает прокси');
  eq(t.env.store.blocked, false, 'unblock сбрасывает флаг');
  eq(t.env.badge.text, 'OFF', 'unblock гасит значок');

  // ── переключатель LAN при блокировке пересобирает обход ───
  t = await boot({ storage: { killSwitchStrict: true } });
  await connect(t); await kill(t);
  t.env.store.lanDirect = false;
  await t.send({ action: 'refreshProxy' });
  assert(isBlockConfig(t.env.proxy) && !t.env.proxy.rules.bypassList.includes('192.168.0.0/16'), 'refreshProxy в блокировке учитывает lanDirect');

  // ── пользователь отключился сам: блокировка не должна остаться ─
  t = await boot({ storage: { killSwitchStrict: true } });
  await connect(t); await kill(t);
  await connect(t);
  await t.send({ action: 'disconnect' });
  eq(t.env.proxy, null, 'ручное отключение снимает прокси');
  eq(t.env.store.blocked, false, 'и флаг блокировки');

  // ── WebRTC ────────────────────────────────────────────────
  t = await boot({ privacy: true, storage: { webrtcProtect: true } });
  await connect(t);
  eq(t.env.policy, 'disable_non_proxied_udp', 'политика WebRTC включена вместе с прокси');
  await t.send({ action: 'disconnect' });
  eq(t.env.policy, null, 'политика снята при отключении');

  t = await boot({ privacy: true });
  await connect(t);
  eq(t.env.policy, null, 'без опции политика не трогается');
  t.env.store.webrtcProtect = true;
  await t.send({ action: 'refreshProxy' });
  eq(t.env.policy, 'disable_non_proxied_udp', 'переключатель применяется сразу');
  t.env.store.webrtcProtect = false;
  await t.send({ action: 'refreshProxy' });
  eq(t.env.policy, null, 'и выключается сразу');

  t = await boot({ privacy: true, storage: { webrtcProtect: true, killSwitchStrict: true } });
  await connect(t); await kill(t);
  eq(t.env.policy, 'disable_non_proxied_udp', 'при строгой блокировке политика WebRTC не снимается');

  t = await boot({ privacy: false, storage: { webrtcProtect: true } });
  eq((await connect(t)).success, true, 'без разрешения privacy подключение работает (политика молча пропущена)');

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
