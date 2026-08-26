// Background Service Worker для управления прокси и native messaging

const NATIVE_HOST_NAME = 'com.vlesschrome.host';

let nativePort = null;
let isConnected = false;
let currentConfig = null;
let socksPort = null;
let stoppingIntentionally = false;

const KEEPALIVE_ALARM = 'keepAlive';
const SOCKS_MISS_LIMIT = 2;
let socksMisses = 0;

// MV3 убивает SW через ~30с простоя. Пока подключены — будим его алармом (0.4 мин
// ~24с), чтобы SW жил, а вместе с ним и native-порт со стартовым процессом Xray.
function startKeepAlive() {
  chrome.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: 0.4 });
}

function stopKeepAlive() {
  chrome.alarms.clear(KEEPALIVE_ALARM);
  socksMisses = 0;
}

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name !== KEEPALIVE_ALARM) return;
  const data = await chrome.storage.local.get(['isConnected', 'socksPort']);
  if (!data.isConnected) {
    stopKeepAlive();
    return;
  }
  socksPort = data.socksPort || socksPort;
  isConnected = true;
  // Kill-switch: popup может быть закрыт. Два промаха SOCKS подряд —
  // снимаем прокси. Таймаут native host НЕ считаем смертью Xray.
  try {
    await runKillSwitchCheck({ immediate: false });
  } catch (e) {
    console.warn('killSwitch:', e);
  }
});

function setBadge(connected) {
  if (connected) {
    chrome.action.setBadgeText({ text: 'ON' });
    chrome.action.setBadgeBackgroundColor({ color: '#10b981' });
  } else {
    chrome.action.setBadgeText({ text: 'OFF' });
    chrome.action.setBadgeBackgroundColor({ color: '#64748b' });
  }
}

// [BUG-1 FIX] Все message-хендлеры ждут завершения инициализации,
// чтобы proxy был гарантированно очищен до ответа на getStatus
const initDone = (async function initBackgroundWorker() {
  try {
    console.log('Background service worker запущен');

    // chrome.storage.session живёт в рамках сессии браузера и гибнет при его
    // закрытии. Так отличаем реальный старт браузера (флага нет) от рутинного
    // перезапуска SW после простоя (флаг уже стоит).
    const sess = await chrome.storage.session.get(['swAlive']);
    await chrome.storage.session.set({ swAlive: true });

    const data = await chrome.storage.local.get([
      'isConnected', 'clientId', 'socksPort', 'proxyNeedsClear'
    ]);

    if (data.proxyNeedsClear) {
      try {
        await clearProxy();
      } catch (error) {
        console.error('Ошибка очистки прокси (proxyNeedsClear):', error);
      }
      await chrome.storage.local.set({ proxyNeedsClear: false });
    }

    if (sess.swAlive && data.isConnected) {
      // Перезапуск SW — НЕ рвём соединение, восстанавливаем (если Xray жив)
      try {
        const r = await nativeHostOneShot({ action: 'status', clientId: data.clientId });
        if (r && r.success && r.data === 'running' && data.socksPort) {
          await setupProxy(data.socksPort);
          socksPort = data.socksPort;
          isConnected = true;
          setBadge(true);
          startKeepAlive();
          console.log('Состояние восстановлено, Xray на порту', data.socksPort);
          return;
        }
      } catch (error) {
        console.error('Не удалось проверить статус Xray:', error);
      }
    }

    // Реальный старт браузера ИЛИ Xray не подтверждён — чистый сброс
    try {
      await clearProxy();
    } catch (error) {
      console.error('Ошибка очистки прокси при старте:', error);
    }

    if (data.isConnected) {
      try {
        await nativeHostOneShot({ action: 'stop', clientId: data.clientId });
      } catch (error) {
        console.error('Ошибка остановки Xray:', error);
      }
      await chrome.storage.local.set({
        isConnected: false,
        connectionStartTime: null
      });
    }

    isConnected = false;
    currentConfig = null;
    socksPort = null;
    setBadge(false);

  } catch (error) {
    console.error('Ошибка инициализации background worker:', error);
  }
})();

// Обработка сообщений от popup
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  // [BUG-1 FIX] Ждём завершения инициализации перед обработкой
  initDone.then(() => {
    handleMessage(request).then(sendResponse).catch(e => {
      sendResponse({ success: false, error: e.message });
    });
  });
  return true;
});

async function handleMessage(request) {
  console.log('Получено сообщение:', request);

  if (request.action === 'connect') {
    return handleConnect(request.vlessUrl, request.config);
  }

  if (request.action === 'disconnect') {
    return handleDisconnect();
  }

  if (request.action === 'getStatus') {
    return { isConnected, config: currentConfig };
  }

  if (request.action === 'pingNative') {
    try {
      const clientId = await getClientId();
      const r = await nativeHostOneShot({ action: 'status', clientId });
      return { success: !!(r && r.success), running: r?.data === 'running' };
    } catch (e) {
      return { success: false, error: e.message };
    }
  }

  if (request.action === 'verifyConnection') {
    if (!isConnected) {
      const data = await chrome.storage.local.get(['isConnected']);
      if (!data.isConnected) {
        return { isConnected: false, alive: false };
      }
    }
    try {
      const r = await runKillSwitchCheck({ immediate: true });
      return {
        isConnected,
        alive: !!r.alive,
        reset: !!r.tripped,
        error: r.error
      };
    } catch (e) {
      console.error('verifyConnection:', e);
      return { isConnected, alive: false, error: e.message };
    }
  }

  if (request.action === 'pingHost') {
    const r = await nativeHostOneShot({
      action: 'ping',
      host: request.host,
      port: request.port,
      transport: request.transport || 'tcp',
      socksPort: request.socksPort,
      timeout: request.timeout
    });
    return {
      success: !!r.success,
      pingMs: r.pingMs,
      error: r.error
    };
  }

  // Поштучные protectSecret/unprotectSecret убраны: popup ходит только батчем.
  // Одиночные команды native host (protect/unprotect) остались — их использует
  // legacySecretBatch как откат для старого хоста.
  if (request.action === 'protectSecrets' || request.action === 'unprotectSecrets') {
    return handleSecretBatch(request);
  }

  return { success: false, error: 'Неизвестная команда' };
}

/** Пакетная шифровка/расшифровка: один запуск native host вместо N. */
async function handleSecretBatch(request) {
  const isProtect = request.action === 'protectSecrets';
  const items = Array.isArray(request.items) ? request.items : [];
  if (items.length === 0) return { success: true, results: [] };

  try {
    const r = await nativeHostOneShot({
      action: isProtect ? 'protectMany' : 'unprotectMany',
      items
    });

    // Расширение обновили, а хост в %LOCALAPPDATA% остался старым (install
    // копирует их раздельно) — он батч не знает. Откатываемся на поштучно.
    if (!r?.success && /неизвестная команда/i.test(r?.error || '')) {
      console.warn('Native host без поддержки батча — поштучный режим');
      return legacySecretBatch(items, isProtect);
    }

    if (!r?.success) throw new Error(r?.error || 'batch failed');
    return { success: true, results: Array.isArray(r.results) ? r.results : [] };
  } catch (e) {
    return { success: false, error: e.message };
  }
}

/** Совместимость со старым native host: по одному сообщению на секрет. */
async function legacySecretBatch(items, isProtect) {
  const results = [];
  for (const item of items) {
    try {
      const r = await nativeHostOneShot({
        action: isProtect ? 'protect' : 'unprotect',
        text: item || ''
      });
      if (r?.success && typeof r.data === 'string') {
        results.push({ ok: true, data: r.data });
      } else {
        results.push({ ok: false, error: r?.error || 'failed' });
      }
    } catch (e) {
      results.push({ ok: false, error: e.message });
    }
  }
  return { success: true, results };
}

// Ищем или создаем уникальный ID профиля
async function getClientId() {
  const data = await chrome.storage.local.get('clientId');
  if (data.clientId) return data.clientId;
  const newId = crypto.randomUUID();
  await chrome.storage.local.set({ clientId: newId });
  return newId;
}

/** Одно сообщение в новом процессе native host (ping, stop без открытого канала). */
function nativeHostOneShot(payload) {
  return new Promise((resolve, reject) => {
    let port;
    let settled = false;
    try {
      port = chrome.runtime.connectNative(NATIVE_HOST_NAME);
    } catch (e) {
      reject(e);
      return;
    }
    const messageId = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    payload.id = messageId;
    const timeout = setTimeout(() => {
      if (settled) return;
      settled = true;
      try {
        port.onMessage.removeListener(listener);
        port.disconnect();
      } catch (_) {}
      reject(new Error('Таймаут ожидания ответа от native host'));
    }, 10000);
    const listener = (response) => {
      if (response.id === messageId) {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        try {
          port.onMessage.removeListener(listener);
          port.disconnect();
        } catch (_) {}
        resolve(response);
      }
    };
    port.onDisconnect.addListener(() => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      const err = chrome.runtime.lastError?.message || 'Native host отключился';
      reject(new Error(err));
    });
    port.onMessage.addListener(listener);
    port.postMessage(payload);
  });
}

// Подключение к VLESS
async function handleConnect(vlessUrl, config) {
  let xrayStarted = false;
  try {
    console.log('Подключение к VLESS...');

    const clientId = await getClientId();

    if (!nativePort) {
      nativePort = chrome.runtime.connectNative(NATIVE_HOST_NAME);

      nativePort.onMessage.addListener((msg) => {
        console.log('Сообщение от native host:', msg);
      });

      nativePort.onDisconnect.addListener(() => {
        console.log('Native host отключен');
        if (chrome.runtime.lastError) {
          console.error('Ошибка native host:', chrome.runtime.lastError.message);
        }
        nativePort = null;
        const intentional = stoppingIntentionally;
        stoppingIntentionally = false;
        if (intentional) return;
        void onNativeHostCrashed();
      });
    }

    // start может идти несколько секунд — даём 45с, чтобы не словить гонку
    const response = await sendNativeMessage({
      action: 'start',
      vlessUrl: vlessUrl,
      config: config,
      clientId: clientId
    }, 45000);

    if (!response || !response.success) {
      throw new Error(response?.error || 'Ошибка запуска Xray');
    }

    if (!response.port) {
      throw new Error('Native host не вернул порт для подключения');
    }

    xrayStarted = true;
    socksPort = response.port;

    await setupProxy(response.port);

    isConnected = true;
    currentConfig = config;
    setBadge(true);

    await chrome.storage.local.set({
      isConnected: true,
      socksPort: response.port,
      connectionStartTime: Date.now()
    });

    startKeepAlive();

    console.log('Успешно подключено на порту', response.port);
    return { success: true };

  } catch (error) {
    console.error('Ошибка подключения:', error);
    // [BUG-3 FIX] Не теряем оригинальную ошибку, если cleanup тоже упадёт.
    // Если Xray уже подтверждён (xrayStarted) — полноценный disconnect.
    // Если нет — НЕ шлём stop (не убиваем чужой/только что стартующий Xray),
    // только чистим прокси и канал.
    try {
      if (xrayStarted) {
        await handleDisconnect();
      } else {
        await clearProxy();
        if (nativePort) { nativePort.disconnect(); nativePort = null; }
        isConnected = false;
        currentConfig = null;
        setBadge(false);
      }
    } catch (disconnectError) {
      console.error('Ошибка при cleanup после неудачного подключения:', disconnectError);
    }
    throw error;
  }
}

async function probeLocalSocks(port) {
  const r = await nativeHostOneShot({
    action: 'ping',
    host: '127.0.0.1',
    port: Number(port),
    transport: 'tcp',
    timeout: 2
  });
  return !!(r && r.success);
}

async function runKillSwitchCheck({ immediate = false } = {}) {
  const data = await chrome.storage.local.get(['isConnected', 'socksPort']);
  if (!data.isConnected || !data.socksPort) {
    socksMisses = 0;
    return { tripped: false, alive: false };
  }

  let ok = false;
  try {
    ok = await probeLocalSocks(data.socksPort);
  } catch (e) {
    console.warn('killSwitch: native host недоступен, не рвём:', e.message);
    return { tripped: false, alive: false, error: e.message };
  }

  if (ok) {
    socksMisses = 0;
    isConnected = true;
    socksPort = data.socksPort;
    return { tripped: false, alive: true };
  }

  socksMisses += 1;
  const limit = immediate ? 1 : SOCKS_MISS_LIMIT;
  console.warn(`killSwitch: SOCKS ${data.socksPort} не отвечает (${socksMisses}/${limit})`);
  if (socksMisses < limit) {
    return { tripped: false, alive: false };
  }

  socksMisses = 0;
  await tripKillSwitch();
  return { tripped: true, alive: false };
}

async function tripKillSwitch() {
  console.warn('Kill-switch: локальный SOCKS мёртв — снимаем прокси');
  isConnected = false;
  currentConfig = null;
  socksPort = null;
  setBadge(false);
  stopKeepAlive();
  await chrome.storage.local.set({
    isConnected: false,
    connectionStartTime: null,
    proxyNeedsClear: true
  });
  try {
    await clearProxy();
    await chrome.storage.local.set({ proxyNeedsClear: false });
  } catch (e) {
    console.error('killSwitch clearProxy:', e);
  }
  try {
    const clientId = await getClientId();
    await nativeHostOneShot({ action: 'stop', clientId });
  } catch (_) { /* xray уже мёртв */ }
  if (nativePort) {
    stoppingIntentionally = true;
    try { nativePort.disconnect(); } catch (_) {}
    nativePort = null;
    stoppingIntentionally = false;
  }
}

async function onNativeHostCrashed() {
  await tripKillSwitch();
}

// Отключение от VLESS
async function handleDisconnect() {
  stoppingIntentionally = true;
  try {
    console.log('Отключение...');
    const clientId = await getClientId();

    if (nativePort) {
      try {
        await sendNativeMessage({ action: 'stop', clientId });
      } catch (error) {
        console.error('Ошибка остановки Xray:', error);
      }
      try {
        nativePort.disconnect();
      } catch (_) { /* already gone */ }
      nativePort = null;
    } else {
      try {
        await nativeHostOneShot({ action: 'stop', clientId });
      } catch (error) {
        console.error('Ошибка остановки Xray (one-shot):', error);
      }
    }

    await clearProxy();

    isConnected = false;
    currentConfig = null;
    socksPort = null;
    setBadge(false);
    stopKeepAlive();

    await chrome.storage.local.set({
      isConnected: false,
      connectionStartTime: null,
      proxyNeedsClear: false
    });

    console.log('Отключено');
    return { success: true };

  } catch (error) {
    console.error('Ошибка отключения:', error);
    throw error;
  } finally {
    stoppingIntentionally = false;
  }
}

// Настройка прокси в Chrome
async function setupProxy(port) {
  return new Promise((resolve, reject) => {
    const config = {
      mode: 'fixed_servers',
      rules: {
        singleProxy: {
          scheme: 'socks5',
          host: '127.0.0.1',
          port: port
        },
        bypassList: ['localhost', '127.0.0.1', '<local>']
      }
    };

    chrome.proxy.settings.set(
      { value: config, scope: 'regular' },
      () => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
        } else {
          console.log('Прокси настроен:', config);
          resolve();
        }
      }
    );
  });
}

// Отключение прокси
async function clearProxy() {
  return new Promise((resolve, reject) => {
    chrome.proxy.settings.clear(
      { scope: 'regular' },
      () => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
        } else {
          console.log('Прокси отключен');
          resolve();
        }
      }
    );
  });
}

// [BUG-2 FIX] Отправка сообщения в native host — с settled guard.
// timeoutMs параметризован: start может занять секунды (запуск Xray), поэтому
// для него таймаут больше (иначе гонка: расширение отваливается по таймауту и
// шлёт stop на только что поднятый Xray).
function sendNativeMessage(message, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    // Держим свою ссылку: onDisconnect в handleConnect обнуляет nativePort,
    // а нам всё ещё надо снять с этого порта слушателей.
    const port = nativePort;
    if (!port) {
      reject(new Error('Native host не подключен'));
      return;
    }

    let settled = false;
    const messageId = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    message.id = messageId;

    const cleanup = () => {
      clearTimeout(timeout);
      try {
        port.onMessage.removeListener(listener);
        port.onDisconnect.removeListener(onDisconnect);
      } catch (_) { /* порт уже уничтожен */ }
    };

    const timeout = setTimeout(() => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error('Таймаут ожидания ответа от native host'));
    }, timeoutMs);

    const listener = (response) => {
      if (response.id !== messageId) return;
      if (settled) return;
      settled = true;
      cleanup();
      resolve(response);
    };

    // Без этого обрыв канала промис не отклонял: если хост не зарегистрирован,
    // не найден Python или битый native-host.bat, connectNative отдаёт живой на
    // вид порт, а падение приходит асинхронно в onDisconnect. handleConnect в
    // этом случае ждал ПОЛНЫЕ 45с таймаута, показывая «Подключение...».
    const onDisconnect = () => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error(chrome.runtime.lastError?.message || 'Native host отключился'));
    };

    port.onMessage.addListener(listener);
    port.onDisconnect.addListener(onDisconnect);

    try {
      port.postMessage(message);
    } catch (e) {
      if (settled) return;
      settled = true;
      cleanup();
      reject(e);
    }
  });
}

// Открытие setup страницы при первой установке
chrome.runtime.onInstalled.addListener(async (details) => {
  if (details.reason === 'install') {
    chrome.tabs.create({
      url: chrome.runtime.getURL('setup.html')
    });
  } else if (details.reason === 'update') {
    console.log('Расширение обновлено до версии', chrome.runtime.getManifest().version);
  }
});
